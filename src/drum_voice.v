// 作用：独立单声道电子底鼓，用三角形 DDS 波形、下滑音高和幅度包络产生 PCM。
// sample 虽未声明 signed，16 位位图按二补码 PCM 解释；0 为静音。
// clk 为 27 MHz 主时钟；fs_tick 为同域单周期采样使能，93.75 kHz，
// 每 288 个主时钟一次。相位、包络与音频计数只在 fs_tick 推进。
// rst_n 低有效异步复位；clear 在 clk 上升沿同步清零，优先于 hit/fs_tick，
// 不必等下个采样使能即可清掉当前声音、待处理击打及输出。
// hit 是调用者给出的 clk 域击打脉冲，此处不检测边沿；velocity 是 8 位力度。
// 两次采样使能之间只保存最新一次击打；同沿 hit/fs_tick 直接使用当前 velocity。
// 零力度事件被消费但不重启声音；已有尾音在该 tick 继续通常的相位/包络更新。
// busy 表示 active 或存在 pending，包含待处理零力度事件及尚未到期的声音窗口；
// 它不是“当前 PCM 非零”标志。每次非零击打重装 18750 tick 的窗口（名义 200 ms）。
// 底鼓没有 LFSR 噪声源；LFSR 与噪声过滤在独立 snare_voice 中实现。
// velocity 范围0..255，不是物理敲击速度；sample 无 valid，fs_tick 更新后保持。
// 无可覆盖模块参数；音高/起音/总窗口由下列固定 localparam 定义。
module drum_voice (
    input             clk,
    input             rst_n,
    input             fs_tick,
    input             clear,
    input             hit,
    input      [7:0]  velocity,
    output reg [15:0] sample,
    output            busy
);

    // 24 位相位的增量按 round(f*2^24/93750) 取整。
    // 起始增量约对应 180 Hz，最低增量约对应 60 Hz；实际值由整数增量决定。
    localparam [15:0] PITCH_START = 16'd32212;
    localparam [15:0] PITCH_FLOOR = 16'd10737;
    localparam [6:0]  ATTACK_TICKS = 7'd64;      // 64 次采样使能，约 0.683 ms
    localparam [14:0] VOICE_TICKS = 15'd18750;   // 18750 tick，名义 200 ms，包含起音

    // pending 在 clk 域捕获击打，active 表示固定窗口尚未结束；相位按 24 位回绕。
    // 即使包络已衰减到零，active/busy 也可继续保持到 tail_remaining 到期。
    reg pending;
    reg [7:0] pending_velocity;
    reg active;
    reg [23:0] phase;
    reg [15:0] pitch_increment;
    // 幅度以 16 位分数增益为主体，额外保留 6 个小数位，所以状态为 22 位 Q6。
    // 渲染时 gain_value[21:6]/65536 才是波形增益；低 6 位供起音/衰减累积。
    reg [21:0] envelope_q6;
    reg [21:0] attack_target_q6;
    reg signed [16:0] attack_step_q6;
    reg [6:0] attack_remaining;
    reg [14:0] tail_remaining;

    // 同沿 hit 优先于旧 pending；event_peak_q6=velocity*2^14。
    // 除去 Q6 后得到 velocity*256 的 16 位增益，即实际峰值增益 velocity/256。
    // start_voice 只在 fs_tick 分支消费；这里的组合条件本身不会更新音频状态。
    wire [7:0] event_velocity = hit ? velocity : pending_velocity;
    wire start_voice = (hit || pending) && (event_velocity != 8'd0);
    wire [21:0] event_peak_q6 = {event_velocity, 14'd0};
    // 差值和累加都先补零/符号扩展为 23 位有符号数，允许复触发时向上或向下起音。
    // 起音步长在事件沿用 delta>>>6 算出，相当于分 64 步逼近；负差值向下取整。
    // 步长量化可能留下误差，所以第 64 步（remaining=1）直接写目标值，不再加步长。
    wire signed [22:0] attack_delta_q6 =
        $signed({1'b0, event_peak_q6}) - $signed({1'b0, envelope_q6});
    wire signed [22:0] attack_sum_q6 =
        $signed({1'b0, envelope_q6}) +
        $signed({{6{attack_step_q6[16]}}, attack_step_q6});
    wire [21:0] attack_envelope_next = (attack_remaining == 7'd1) ?
        attack_target_q6 : attack_sum_q6[21:0];
    // 起音后每 tick 衰减 floor(envelope/2048)+1 个 Q6 单位。
    // >> 的输入是非负无符号包络，这里等同于除以 2048 后取整。
    // 额外 +1 防止小值因移位变零而永久停滞；不足以再减时直接钳到 0。
    // 窗口到期也强制清零。该离散递推描述幅度变化，不承诺具体听感。
    wire [21:0] decay_drop = (envelope_q6 >> 11) + 22'd1;
    wire [21:0] decay_envelope_next = (envelope_q6 > decay_drop) ?
        envelope_q6 - decay_drop : 22'd0;
    // 通常采样用当前 pitch_increment 推进相位；复触发用 PITCH_START 推进相位。
    // 复触发保留原相位轨迹而不归零，但在该 tick 立即使用新的起始音高步长。
    wire [23:0] phase_next = phase + {8'd0, pitch_increment};
    wire [23:0] retrigger_phase = phase + {8'd0, PITCH_START};

    assign busy = active || pending;

    // phase[22] 决定三角形幅值上升/下降，phase[23] 决定正负半周。
    // phase[21:9] 给出 13 位幅值，最大为 8191；不使用正弦 ROM。
    // 先计算非负幅值乘增益，再取 product[28:16]（丢弃 16 个小数位），最后恢复符号。
    // 因而微小正负幅值都可截断为 0；直接对负乘积 >>>16 会可能留下 -1。
    // 最大增益为 255/256，所以峰值 floor(8191*255/256)=8159，无须在此额外饱和。
    function [15:0] render_sample;
        input [23:0] phase_value;
        input [21:0] gain_value;
        reg [12:0] triangle_magnitude;
        reg [28:0] gain_product;
        reg [15:0] pcm_magnitude;
        begin
            // 取反只作用于 13 位幅值，形成上/下坡；乘法使用 13+16=29 位非负结果。
            triangle_magnitude = phase_value[22] ?
                ~phase_value[21:9] : phase_value[21:9];
            gain_product = triangle_magnitude * gain_value[21:6];
            pcm_magnitude = {3'd0, gain_product[28:16]};
            // 对缩放后的幅值取反加一得到二补码负值，正负极性共享同一截断幅值。
            render_sample = phase_value[23] ?
                (~pcm_magnitude + 16'd1) : pcm_magnitude;
        end
    endfunction

    // 异步复位清空所有状态，默认音高设到下限；后续非零击打再装载起始音高。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending <= 1'b0;
            pending_velocity <= 8'd0;
            active <= 1'b0;
            phase <= 24'd0;
            pitch_increment <= PITCH_FLOOR;
            envelope_q6 <= 22'd0;
            attack_target_q6 <= 22'd0;
            attack_step_q6 <= 17'sd0;
            attack_remaining <= 7'd0;
            tail_remaining <= 15'd0;
            sample <= 16'd0;
        // 同步 clear 与复位清理内容相同，优先级高于事件捕获和采样处理。
        end else if (clear) begin
            pending <= 1'b0;
            pending_velocity <= 8'd0;
            active <= 1'b0;
            phase <= 24'd0;
            pitch_increment <= PITCH_FLOOR;
            envelope_q6 <= 22'd0;
            attack_target_q6 <= 22'd0;
            attack_step_q6 <= 17'sd0;
            attack_remaining <= 7'd0;
            tail_remaining <= 15'd0;
            sample <= 16'd0;
        end else begin
            // 单槽事件缓存：若连续收到击打而尚未采样，最新力度覆盖旧力度。
            if (hit) begin
                pending <= 1'b1;
                pending_velocity <= velocity;
            end

            if (fs_tick) begin
                // 更后的 pending<=0 覆盖上方同沿的 pending<=1，事件恰好消费一次。
                // hit 同时有效时，event_velocity 已选当前力度，避免误用旧缓存。
                pending <= 1'b0;
                // 非零事件优先于尾音计时：重装起音目标、64 步计数和总窗口。
                // 本沿只设置步长；包络的 64 次起音更新从后续 fs_tick 开始。
                if (start_voice) begin
                    active <= 1'b1;
                    pitch_increment <= PITCH_START;
                    attack_target_q6 <= event_peak_q6;
                    attack_step_q6 <= attack_delta_q6 >>> 6;
                    attack_remaining <= ATTACK_TICKS;
                    tail_remaining <= VOICE_TICKS;
                    if (active) begin
                        // 已有声音复触发：保留当前增益，本沿以新音高推进相位。
                        // 后续 64 tick 可向上或向下走到新力度；不会先把包络/相位硬清零。
                        phase <= retrigger_phase;
                        sample <= render_sample(retrigger_phase, envelope_q6);
                    // 从空闲启动则先输出 0，相位/包络归零，下一 tick 才开始起音。
                    end else begin
                        phase <= 24'd0;
                        envelope_q6 <= 22'd0;
                        sample <= 16'd0;
                    end
                end else if (active) begin
                    // 总窗口到期优先于波形渲染，清掉活动标志、计数和输出，结束 busy。
                    if (tail_remaining <= 15'd1) begin
                        active <= 1'b0;
                        phase <= 24'd0;
                        pitch_increment <= PITCH_FLOOR;
                        envelope_q6 <= 22'd0;
                        attack_target_q6 <= 22'd0;
                        attack_step_q6 <= 17'sd0;
                        attack_remaining <= 7'd0;
                        tail_remaining <= 15'd0;
                        sample <= 16'd0;
                    end else begin
                        tail_remaining <= tail_remaining - 15'd1;
                        phase <= phase_next;
                        // 单调音高下滑：每次减 floor((pitch-floor)/1024)+1。
                        // +1 保证最终到达下限；达到下限后不再更新。phase_next 使用本沿前的增量。
                        if (pitch_increment > PITCH_FLOOR)
                            pitch_increment <= pitch_increment -
                                (((pitch_increment - PITCH_FLOOR) >> 10) + 16'd1);
                        // 起音期间渲染更新后的包络；起音结束后切换至衰减包络。
                        if (attack_remaining != 7'd0) begin
                            attack_remaining <= attack_remaining - 7'd1;
                            envelope_q6 <= attack_envelope_next;
                            sample <= render_sample(phase_next, attack_envelope_next);
                        end else begin
                            envelope_q6 <= decay_envelope_next;
                            sample <= render_sample(phase_next, decay_envelope_next);
                        end
                    end
                // 空闲采样时明确输出零；fs_tick 之间 sample 保持，不会组合跟随相位。
                end else begin
                    sample <= 16'd0;
                end
            end
        end
    end
endmodule
