// 作用：独立单声道电子军鼓，将 LFSR 噪声与固定音高三角形主体分别加包络后混合。
// sample 是 signed 的 16 位二补码 PCM，0 为静音；不是无符号偏置音频。
// clk 为 27 MHz 主时钟；fs_tick 是其域内单周期采样使能，93.75 kHz，
// 每 288 个主时钟一次。音频状态、相位和 LFSR 只在活动的 fs_tick 推进。
// rst_n 低有效异步清零；clear 为 clk 沿的同步清零，优先于击打/采样处理，
// 即使当前没有 fs_tick 也清空声音、滤波历史和待处理事件。
// hit 为调用者产生的主时钟脉冲，此处不做边沿检测；velocity 为 8 位力度。
// pending 在主时钟域保存最新击打；同沿 hit/fs_tick 使用当前力度并只消费一次。
// 零力度事件不重启已有声音，已有声音仍在该 tick 执行通常的更新。
// busy=active||pending，包含等待事件及未到期窗口，不等于 PCM 是否非零。
// 非零击打重装 64 tick 起音和 16875 tick 总窗口（名义 180 ms，含起音）。
// velocity 为0..255无单位力度；sample 无 valid，fs_tick 更新后保持。
// 无可覆盖模块参数；固定音高、种子、起音和总窗口见下列 localparam。
// 复触发时相位/LFSR/滤波历史继续正常推进，本沿保留当前两路增益，随后分别
// 用 64 步升/降到新力度；从空闲启动则重新使用固定种子，清零相位和滤波历史。
module snare_voice (
    input                    clk,
    input                    rst_n,
    input                    fs_tick,
    input                    clear,
    input                    hit,
    input      [7:0]         velocity,
    output reg signed [15:0] sample,
    output                   busy
);

    localparam [23:0] PHASE_STEP = 24'd37581;  // 24 位 DDS 步长，名义约 210 Hz
    localparam [16:0] NOISE_SEED = 17'h1ace1; // 非零固定种子，反馈取第 16/13 位异或
    localparam [6:0] ATTACK_TICKS = 7'd64;    // 64 次采样使能，约 0.683 ms
    // 16875/93750=0.18 秒；每次非零复触发都会重新装载整个窗口。
    localparam [14:0] VOICE_TICKS = 15'd16875;

    // pending/力度缓存在 clk 域更新；活动音频状态在 fs_tick 更新。
    // active 到期才撤销；即使两路包络已经降为零，窗口内 busy 仍可为真。
    reg pending;
    reg [7:0] pending_velocity;
    reg active;
    reg [23:0] phase;
    reg [16:0] noise_lfsr;
    // 两个有符号滤波历史均为 Q4：16 个内部单位对应 1 个整数噪声幅值。
    // 输入幅值上限为 8191，转成 Q4 是 131056；19 位历史足够表示其正负范围。
    // 主路低通抑制快速变化，慢速低通估计主路均值，二者相减去掉较慢分量。
    reg signed [18:0] noise_lp_q4;
    reg signed [18:0] noise_dc_q4;
    // 两路各持有 22 位 Q6 包络：高 16 位是分数增益，低 6 位用于细化步进。
    // 共用目标力度但各自从当前增益算步长，故复触发不会强制把两路当前增益拉成相同。
    reg [21:0] noise_envelope_q6;
    reg [21:0] body_envelope_q6;
    reg [21:0] attack_target_q6;
    reg signed [16:0] noise_attack_step_q6;
    reg signed [16:0] body_attack_step_q6;
    reg [6:0] attack_remaining;
    reg [14:0] tail_remaining;

    assign busy = active || pending;

    // 当前 hit 优先于旧缓存；零力度只消费事件。
    // event_peak_q6=velocity*2^14；渲染时取高 16 位再除 65536，峰值增益为 velocity/256。
    wire [7:0] event_velocity = hit ? velocity : pending_velocity;
    wire start_voice = (hit || pending) && (event_velocity != 8'd0);
    wire [21:0] event_peak_q6 = {event_velocity, 14'd0};
    // 23 位有符号差值允许新力度比旧包络更小；累加前显式扩展步长符号。
    // delta>>>6 为 64 步起音的量化步长，负差值向负无穷取整；最后一步强制命中目标。
    wire signed [22:0] noise_attack_delta_q6 =
        $signed({1'b0, event_peak_q6}) -
        $signed({1'b0, noise_envelope_q6});
    wire signed [22:0] body_attack_delta_q6 =
        $signed({1'b0, event_peak_q6}) -
        $signed({1'b0, body_envelope_q6});
    wire signed [22:0] noise_attack_sum_q6 =
        $signed({1'b0, noise_envelope_q6}) +
        $signed({{6{noise_attack_step_q6[16]}}, noise_attack_step_q6});
    wire signed [22:0] body_attack_sum_q6 =
        $signed({1'b0, body_envelope_q6}) +
        $signed({{6{body_attack_step_q6[16]}}, body_attack_step_q6});
    // 噪声每 tick 减 floor(env/1024)+1，主体减 floor(env/2048)+1。
    // 相同包络值下噪声递减更快；非负包络用 >>，不会涉及负数补符号位。
    wire [21:0] noise_decay_drop = (noise_envelope_q6 >> 10) + 22'd1;
    wire [21:0] body_decay_drop = (body_envelope_q6 >> 11) + 22'd1;
    // +1 防止移位量化成零后永久停滞，剩余包络不够扣除时直接钳到 0。
    // 这是代码中的离散衰减律；不据此编造精确听感或模拟器件的衰减特性。
    wire [21:0] noise_decay_next =
        (noise_envelope_q6 > noise_decay_drop) ?
        noise_envelope_q6 - noise_decay_drop : 22'd0;
    wire [21:0] body_decay_next =
        (body_envelope_q6 > body_decay_drop) ?
        body_envelope_q6 - body_decay_drop : 22'd0;
    // 起音未完成时选逐步累加值，remaining=1 直接选目标；之后选各路衰减值。
    wire [21:0] noise_envelope_next = (attack_remaining != 7'd0) ?
        ((attack_remaining == 7'd1) ? attack_target_q6 :
         noise_attack_sum_q6[21:0]) : noise_decay_next;
    wire [21:0] body_envelope_next = (attack_remaining != 7'd0) ?
        ((attack_remaining == 7'd1) ? attack_target_q6 :
         body_attack_sum_q6[21:0]) : body_decay_next;
    // 主体音高没有底鼓式下滑：每个活动 tick 都加同一个 24 位 PHASE_STEP 并回绕。
    wire [23:0] phase_next = phase + PHASE_STEP;

    // 17 位移位寄存器把旧 [15:0] 左移，新的最低位为旧 [16] XOR [13]。
    // 它是确定性的伪随机序列，不是真随机源；非零种子避免全零状态被异或反馈锁住。
    // 复触发不重新播种，冷启动/窗口结束/clear/复位才恢复固定种子。
    wire [16:0] noise_lfsr_next =
        {noise_lfsr[15:0], noise_lfsr[16] ^ noise_lfsr[13]};
    // 用下一 LFSR 状态的 [16] 选符号、[15:3] 取 13 位幅值，低 3 位不参与幅值。
    // 幅值尾接四个零转换为 Q4，前面补零后显式 $signed，再按符号决定是否取负。
    // 正负分支共享 0..8191 的幅值范围；这不意味着序列每段都有完全相同的统计分布。
    wire signed [19:0] noise_input_q4 = noise_lfsr_next[16] ?
        -$signed({3'd0, noise_lfsr_next[15:3], 4'd0}) :
         $signed({3'd0, noise_lfsr_next[15:3], 4'd0});
    // 19 位历史先复制符号位扩到 20 位，差分和下一状态在同一有符号 Q4 尺度中计算。
    wire signed [19:0] noise_lp_wide =
        $signed({noise_lp_q4[18], noise_lp_q4});
    wire signed [19:0] noise_dc_wide =
        $signed({noise_dc_q4[18], noise_dc_q4});
    wire signed [19:0] noise_lp_error = noise_input_q4 - noise_lp_wide;
    // 主路：lp_next = lp + (input-lp)/4 的算术右移实现，保留 Q4 小数。
    // 慢均值：dc_next = dc + (lp_next-dc)/32，输入使用本 tick 新算出的 lp_next。
    // >>> 对负差值向负无穷取整，不能等同于有符号 / 的向零截断。
    // 两个系数只描述离散过滤运算，不在注释中假定精确 Hz 截止或实际听感。
    wire signed [19:0] noise_lp_next =
        noise_lp_wide + (noise_lp_error >>> 2);
    wire signed [19:0] noise_dc_error = noise_lp_next - noise_dc_wide;
    wire signed [19:0] noise_dc_next =
        noise_dc_wide + (noise_dc_error >>> 5);
    // 新主路减新慢均值得到噪声分量，>>>4 从 Q4 转回整数幅值。
    // 先钳位到 +/-6143，再进入包络乘法，避免过滤瞬态直接占满混合范围。
    wire signed [19:0] noise_highpass_q4 = noise_lp_next - noise_dc_next;
    wire signed [19:0] noise_highpass = noise_highpass_q4 >>> 4;
    wire signed [13:0] noise_bounded = (noise_highpass > 20'sd6143) ?
        14'sd6143 : ((noise_highpass < -20'sd6143) ?
        -14'sd6143 : noise_highpass[13:0]);

    // 渲染先限制各路：噪声幅值 <=6143，三角形主体幅值 <=2047。
    // 增益不超过 255/256，缩放后各路幅值 <=6119、2039，混合幅值 <=8158。
    // 先对非负幅值乘增益并截去 16 位，再恢复符号，让微小正负结果都可归零。
    // 若直接对负乘积做 >>>16，则小负数可能残留 -1；这里的幅值法避免该输出残差。
    // 前级 Q4 滤波仍采用算术右移，不能把最终幅值法理解为整条链路完全无量化偏差。
    function signed [15:0] render_sample;
        input [23:0] phase_value;
        input signed [13:0] noise_value;
        input [21:0] noise_gain;
        input [21:0] body_gain;
        reg [13:0] noise_magnitude;
        reg [10:0] body_magnitude;
        reg [29:0] noise_product;
        reg [26:0] body_product;
        reg [13:0] noise_scaled;
        reg [10:0] body_scaled;
        reg signed [15:0] noise_pcm;
        reg signed [15:0] body_pcm;
        begin
            // 噪声二补码转非负幅值；主体用 phase[22] 折叠 11 位三角形幅值。
            noise_magnitude = noise_value[13] ?
                (~noise_value + 14'd1) : noise_value;
            body_magnitude = phase_value[22] ?
                ~phase_value[21:11] : phase_value[21:11];
            // 14x16 和 11x16 位非负乘积分别用 30/27 位保存。
            // 取高位等效于非负乘积除 65536 向下取整；包络低 6 位此时不参与乘法。
            noise_product = noise_magnitude * noise_gain[21:6];
            body_product = body_magnitude * body_gain[21:6];
            noise_scaled = noise_product[29:16];
            body_scaled = body_product[26:16];
            // 扩展已缩放的非负幅值后再恢复符号，最后做有符号 16 位混合。
            // 这里没有单独的总和饱和器；安全范围来自前面的各路限幅与峰值增益约束。
            noise_pcm = noise_value[13] ?
                -$signed({2'd0, noise_scaled}) :
                 $signed({2'd0, noise_scaled});
            body_pcm = phase_value[23] ?
                -$signed({5'd0, body_scaled}) :
                 $signed({5'd0, body_scaled});
            render_sample = noise_pcm + body_pcm;
        end
    endfunction

    // 异步复位清零事件、包络、相位、Q4 历史和输出，并恢复非零 LFSR 种子。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending <= 1'b0;
            pending_velocity <= 8'd0;
            active <= 1'b0;
            phase <= 24'd0;
            noise_lfsr <= NOISE_SEED;
            noise_lp_q4 <= 19'sd0;
            noise_dc_q4 <= 19'sd0;
            noise_envelope_q6 <= 22'd0;
            body_envelope_q6 <= 22'd0;
            attack_target_q6 <= 22'd0;
            noise_attack_step_q6 <= 17'sd0;
            body_attack_step_q6 <= 17'sd0;
            attack_remaining <= 7'd0;
            tail_remaining <= 15'd0;
            sample <= 16'sd0;
        // 同步 clear 清理内容与复位相同，不等采样使能，优先于任何击打。
        end else if (clear) begin
            pending <= 1'b0;
            pending_velocity <= 8'd0;
            active <= 1'b0;
            phase <= 24'd0;
            noise_lfsr <= NOISE_SEED;
            noise_lp_q4 <= 19'sd0;
            noise_dc_q4 <= 19'sd0;
            noise_envelope_q6 <= 22'd0;
            body_envelope_q6 <= 22'd0;
            attack_target_q6 <= 22'd0;
            noise_attack_step_q6 <= 17'sd0;
            body_attack_step_q6 <= 17'sd0;
            attack_remaining <= 7'd0;
            tail_remaining <= 15'd0;
            sample <= 16'sd0;
        end else begin
            // 未到 fs_tick 时只缓存最新力度；连续 hit 会覆盖而不会排队多个事件。
            if (hit) begin
                pending <= 1'b1;
                pending_velocity <= velocity;
            end
            // pending 在这里清零，覆盖同沿上方置位；当前 hit 的力度直接消费一次。
            if (fs_tick) begin
                pending <= 1'b0;
                // 新非零击打优先于旧尾音到期，重装两个起音步长及整个声音窗口。
                if (start_voice) begin
                    active <= 1'b1;
                    attack_target_q6 <= event_peak_q6;
                    noise_attack_step_q6 <= noise_attack_delta_q6 >>> 6;
                    body_attack_step_q6 <= body_attack_delta_q6 >>> 6;
                    attack_remaining <= ATTACK_TICKS;
                    tail_remaining <= VOICE_TICKS;
                    if (active) begin
                        // 复触发本沿仍推进相位、LFSR 和滤波器，保持声音状态连续。
                        // 此沿使用旧的两路增益输出；新的 64 步起音从后续 tick 开始。
                        phase <= phase_next;
                        noise_lfsr <= noise_lfsr_next;
                        noise_lp_q4 <= noise_lp_next[18:0];
                        noise_dc_q4 <= noise_dc_next[18:0];
                        sample <= render_sample(phase_next, noise_bounded,
                            noise_envelope_q6, body_envelope_q6);
                    // 从空闲启动先归零输出/滤波/增益并恢复种子，再在后续 tick 起音。
                    end else begin
                        phase <= 24'd0;
                        noise_lfsr <= NOISE_SEED;
                        noise_lp_q4 <= 19'sd0;
                        noise_dc_q4 <= 19'sd0;
                        noise_envelope_q6 <= 22'd0;
                        body_envelope_q6 <= 22'd0;
                        sample <= 16'sd0;
                    end
                end else if (active) begin
                    // 到期强制撤销 active，清掉所有音频历史和输出，使下一次冷启动可重复。
                    if (tail_remaining <= 15'd1) begin
                        active <= 1'b0;
                        phase <= 24'd0;
                        noise_lfsr <= NOISE_SEED;
                        noise_lp_q4 <= 19'sd0;
                        noise_dc_q4 <= 19'sd0;
                        noise_envelope_q6 <= 22'd0;
                        body_envelope_q6 <= 22'd0;
                        attack_target_q6 <= 22'd0;
                        noise_attack_step_q6 <= 17'sd0;
                        body_attack_step_q6 <= 17'sd0;
                        attack_remaining <= 7'd0;
                        tail_remaining <= 15'd0;
                        sample <= 16'sd0;
                    end else begin
                        // 使用组合算出的“下一”相位、噪声、滤波和包络渲染本 tick 输出。
                        // 非阻塞寄存器写回与该输出对应，而非用旧历史再多拖一个采样。
                        tail_remaining <= tail_remaining - 15'd1;
                        phase <= phase_next;
                        noise_lfsr <= noise_lfsr_next;
                        noise_lp_q4 <= noise_lp_next[18:0];
                        noise_dc_q4 <= noise_dc_next[18:0];
                        noise_envelope_q6 <= noise_envelope_next;
                        body_envelope_q6 <= body_envelope_next;
                        if (attack_remaining != 7'd0)
                            attack_remaining <= attack_remaining - 7'd1;
                        sample <= render_sample(phase_next, noise_bounded,
                            noise_envelope_next, body_envelope_next);
                    end
                // 空闲 tick 输出 0，音频历史不再推进；无 fs_tick 时输出/音频状态保持。
                end else begin
                    sample <= 16'sd0;
                end
            end
        end
    end
endmodule
