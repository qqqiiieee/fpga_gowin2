// 有界的32声部振荡器诊断控制器；仅输出控制，不创建音源、不修改串行时钟。
// keys 已在 clk 域消抖，bit0..15 对应 S1..S16，1 表示按下；remote_active
// 表示当前键盘来源。sample_tick 是 clk 域的采样使能，不能作为独立时钟。
// 默认 fs=93750Hz：进入长按2s、ACTIVE无有效操作60s退出、扫频半段0.5s；
// 增益每8个采样改变1/256，完整单向渐变约21.845ms。所有计时均有上界。
// test_mode 供同一音频引擎选择测试正弦；gate_mask 的低位依次对应声部0..31。
// requested_count 表示请求的声部数，扫频期间始终为32，OFF时实际只开31声部。
// master_gain 为0..256的Q8倍率（下游乘后右移8位），256表示正常满幅。
// clear_audio 仅在零增益切换模式时拉高一个 clk 周期，可接同 clk 音频寄存器
// 的异步复位：audio_rst_n = rst_n && !clear_audio；不可用于PT8211/串行时钟复位。
// 本模块不驱动音频复位网络；下游还须遵守异步复位释放的时序约束。
// clk 为27MHz主时钟，rst_n 异步低有效；复位NORMAL、test_mode=0、gain=256。
// 参数默认 HOLD/MAX/SWEEP_HALF/RAMP=187500/5625000/46875/8，
// 单位均为采样数（RAMP为每增益步的采样数）；非正值按1，宽度按正门槛计算。
// 参数算术使用integer，覆盖值须落在其可表示范围；不是任意无限长计时器。
// owned 是 state!=NORMAL 的持续所有权，包含进/出测试的淡入淡出与等待松键，
// 不能把 owned 等同 test_mode 或“PCM为零”。clear_audio 是唯一清零事件脉冲。
// state_debug：0正常、1演奏淡出、2测试淡入、3测试活动、4退出淡出、
// 5等待全松、6演奏淡入；gate_mask/请求数/扫频状态更新后保持。
// S13+S15恰好双键长按进入，S1..S5选1/4/8/16/32声部，S6启动逐路OFF/ON，
// S16新单键上升沿退出；按键边沿在每 clk 识别，计时与渐变用 sample_tick。
// WAIT_RELEASE 等干净全松才恢复；无按键释放承诺，测试超时不是强行复位键盘。
module oscillator_test_control #(
    parameter integer HOLD_SAMPLES       = 187500,
    parameter integer MAX_SAMPLES        = 5625000,
    parameter integer SWEEP_HALF_SAMPLES = 46875,
    parameter integer RAMP_DIV           = 8
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sample_tick,
    input  wire [15:0] keys,
    input  wire        ghost,
    input  wire        remote_active,
    output wire        owned,
    output reg         test_mode,
    output reg  [31:0] gate_mask,
    output reg  [5:0]  requested_count,
    output reg         sweep_active,
    output reg  [4:0]  sweep_index,
    output reg  [8:0]  master_gain,
    output reg         clear_audio,
    output wire [3:0]  state_debug,
    // 允许普通输入与输出所有权分开：退出渐入时必须接收新按下/松开/鼓击。
    // owned 仍覆盖这段渐入，使音量渐变、菜单和教学暂停规则保持不变。
    output wire        normal_input_ready
);
    // count只需容纳0..LIMIT-1；LIMIT=1仍至少1位，避免[-1:0]或零宽寄存器。
    // 仿真/综合传入0或负参数时按1处理，既不回绕，也不生成永不结束的状态。
    function integer count_width;
        input integer limit;
        integer remaining;
        begin
            remaining = limit - 1;
            count_width = 0;
            while (remaining > 0) begin
                count_width = count_width + 1;
                remaining = remaining >> 1;
            end
            if (count_width < 1) count_width = 1;
        end
    endfunction

    localparam integer HOLD_LIMIT  = (HOLD_SAMPLES > 0) ? HOLD_SAMPLES : 1;
    localparam integer IDLE_LIMIT  = (MAX_SAMPLES > 0) ? MAX_SAMPLES : 1;
    localparam integer SWEEP_LIMIT = (SWEEP_HALF_SAMPLES > 0) ? SWEEP_HALF_SAMPLES : 1;
    localparam integer RAMP_LIMIT  = (RAMP_DIV > 0) ? RAMP_DIV : 1;
    localparam integer HOLD_WIDTH  = count_width(HOLD_LIMIT);
    localparam integer IDLE_WIDTH  = count_width(IDLE_LIMIT);
    localparam integer SWEEP_WIDTH = count_width(SWEEP_LIMIT);
    localparam integer RAMP_WIDTH  = count_width(RAMP_LIMIT);

    // state_debug编码固定，方便独立TB以及将来状态监视器直接解释。
    localparam [3:0] NORMAL          = 4'd0;
    localparam [3:0] FADE_NORMAL_OUT = 4'd1;
    localparam [3:0] FADE_TEST_IN    = 4'd2;
    localparam [3:0] ACTIVE          = 4'd3;
    localparam [3:0] FADE_OUT        = 4'd4;
    localparam [3:0] WAIT_RELEASE    = 4'd5;
    localparam [3:0] FADE_NORMAL_IN  = 4'd6;

    reg [3:0] state;
    reg [HOLD_WIDTH-1:0] hold_count;
    reg [IDLE_WIDTH-1:0] idle_count;
    reg [SWEEP_WIDTH-1:0] sweep_count;
    reg [RAMP_WIDTH-1:0] ramp_count;
    reg [15:0] previous_keys;
    reg hold_source;
    reg entry_source;
    reg source_exit_seen;
    reg controls_armed;
    reg sweep_on;

    assign owned = (state != NORMAL);
    assign state_debug = state;
    assign normal_input_ready=(state==NORMAL || state==FADE_NORMAL_IN);

    wire entry_chord = !ghost && (keys == 16'h5000); // 恰好S13+S15。
    wire clean_release = !ghost && (keys == 16'h0000);
    // 每个clk记录原始消抖键状态，包括ghost/无效组合；解除ghost或松开额外键
    // 不会伪造已按住控制键的上升沿。控制动作不必等到sample_tick才能识别。
    wire [15:0] rising_keys = keys & ~previous_keys;
    wire exit_key = !ghost && (keys == 16'h8000) && rising_keys[15];
    wire count_1  = !ghost && (keys == 16'h0001) && rising_keys[0];
    wire count_4  = !ghost && (keys == 16'h0002) && rising_keys[1];
    wire count_8  = !ghost && (keys == 16'h0004) && rising_keys[2];
    wire count_16 = !ghost && (keys == 16'h0008) && rising_keys[3];
    wire count_32 = !ghost && (keys == 16'h0010) && rising_keys[4];
    wire start_sweep = !ghost && (keys == 16'h0020) && rising_keys[5];
    wire new_control = controls_armed &&
                       (count_1 || count_4 || count_8 || count_16 || count_32 || start_sweep);
    // 来源切换只触发一次退出；切换后remote_active可以长期保持新值，不能因此
    // 在恢复正常音量时反复退出、永久卡在owned。S16的新上升沿仍可取消恢复。
    wire source_exit = owned && !source_exit_seen && (remote_active != entry_source);
    wire ramp_step = sample_tick && (ramp_count >= RAMP_LIMIT - 1);

    // 模式切换先降增益到零再清音频状态；声部淡入淡出与控制所有权由各状态区分。
    // previous_keys 每 clk 跟踪，即使当前键组合无效也不伪造后续新按键边沿。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= NORMAL;
            test_mode <= 1'b0;
            gate_mask <= 32'd0;
            requested_count <= 6'd0;
            sweep_active <= 1'b0;
            sweep_index <= 5'd0;
            master_gain <= 9'd256;
            clear_audio <= 1'b0;
            hold_count <= 0;
            idle_count <= 0;
            sweep_count <= 0;
            ramp_count <= 0;
            previous_keys <= 16'd0;
            hold_source <= 1'b0;
            entry_source <= 1'b0;
            source_exit_seen <= 1'b0;
            controls_armed <= 1'b0;
            sweep_on <= 1'b0;
        end else begin
            // 无论sample_tick是否发生，都在下一clk撤销清零，保证单clk脉冲。
            clear_audio <= 1'b0;
            previous_keys <= keys;
            if (source_exit) source_exit_seen <= 1'b1;

            // 退出优先于准备完成、测试渐入完成以及任何控制/扫频推进。
            // 已在FADE_OUT/WAIT_RELEASE时不重置渐变计数，否则持续输入会拖延退出。
            if (owned && (exit_key || source_exit) &&
                (state != FADE_OUT) && (state != WAIT_RELEASE)) begin
                state <= FADE_OUT;
                ramp_count <= 0;
                idle_count <= 0;
                controls_armed <= 1'b0;
                sweep_active <= 1'b0; // 冻结当前gate后淡出，不再切换扫频半段。
                sweep_count <= 0;
            end else begin
                case (state)
                    NORMAL: begin
                        master_gain <= 9'd256;
                        hold_count <= 0;
                        source_exit_seen <= 1'b0;
                        // 即使两次采样之间出现短暂无效/ghost/来源变化，也破坏连续意图。
                        // 不跨输入来源拼接长按时间；HOLD_LIMIT个有效采样才获得owned。
                        if (entry_chord) begin
                            if ((hold_count != 0) && (remote_active != hold_source)) begin
                                hold_count <= 0;
                            end else if (sample_tick) begin
                                hold_source <= remote_active;
                                if (hold_count >= HOLD_LIMIT - 1) begin
                                    state <= FADE_NORMAL_OUT;
                                    entry_source <= remote_active;
                                    ramp_count <= 0;
                                    idle_count <= 0;
                                    controls_armed <= 1'b0;
                                    sweep_active <= 1'b0;
                                    sweep_index <= 5'd0;
                                    sweep_count <= 0;
                                    sweep_on <= 1'b0;
                                end else begin
                                    hold_count <= hold_count + 1'b1;
                                end
                            end else begin
                                hold_count <= hold_count;
                            end
                        end
                    end

                    FADE_NORMAL_OUT: begin
                        if (sample_tick) begin
                            if (ramp_step) begin
                                ramp_count <= 0;
                                if (master_gain <= 9'd1) begin
                                    master_gain <= 9'd0;
                                    clear_audio <= 1'b1;
                                    test_mode <= 1'b1;
                                    gate_mask <= 32'hffffffff;
                                    requested_count <= 6'd32;
                                    state <= FADE_TEST_IN;
                                end else master_gain <= master_gain - 1'b1;
                            end else ramp_count <= ramp_count + 1'b1;
                        end
                    end

                    FADE_TEST_IN: begin
                        if (sample_tick) begin
                            if (ramp_step) begin
                                ramp_count <= 0;
                                if (master_gain >= 9'd255) begin
                                    master_gain <= 9'd256;
                                    state <= ACTIVE;
                                    idle_count <= 0;
                                    // 到ACTIVE以后才接受全部清洁松键，准备期间的松键
                                    // 不能使仍按住的控制键在ACTIVE第一次使用时生效。
                                    controls_armed <= 1'b0;
                                end else master_gain <= master_gain + 1'b1;
                            end else ramp_count <= ramp_count + 1'b1;
                        end
                    end

                    ACTIVE: begin
                        if (clean_release) controls_armed <= 1'b1;
                        if (new_control) begin
                            // 真正的新控制优先于同一采样的超时；长按和扫频内部跳转
                            // 都不能刷新idle_count，通信保活也不是控制事件。
                            idle_count <= 0;
                            sweep_count <= 0;
                            sweep_index <= 5'd0;
                            sweep_on <= 1'b0;
                            sweep_active <= start_sweep;
                            if (count_1) begin
                                requested_count <= 6'd1;
                                gate_mask <= 32'h00000001;
                            end else if (count_4) begin
                                requested_count <= 6'd4;
                                gate_mask <= 32'h0000000f;
                            end else if (count_8) begin
                                requested_count <= 6'd8;
                                gate_mask <= 32'h000000ff;
                            end else if (count_16) begin
                                requested_count <= 6'd16;
                                gate_mask <= 32'h0000ffff;
                            end else begin
                                requested_count <= 6'd32;
                                gate_mask <= start_sweep ? 32'hfffffffe : 32'hffffffff;
                            end
                        end else if (sample_tick) begin
                            if (idle_count >= IDLE_LIMIT - 1) begin
                                state <= FADE_OUT;
                                ramp_count <= 0;
                                idle_count <= 0;
                                controls_armed <= 1'b0;
                                sweep_active <= 1'b0;
                                sweep_count <= 0;
                            end else begin
                                idle_count <= idle_count + 1'b1;
                                if (sweep_active) begin
                                    if (sweep_count >= SWEEP_LIMIT - 1) begin
                                        sweep_count <= 0;
                                        if (!sweep_on) begin
                                            sweep_on <= 1'b1;
                                            gate_mask <= 32'hffffffff;
                                        end else if (sweep_index == 5'd31) begin
                                            // 声部31的ON完整保持半段后结束；索引不回绕。
                                            sweep_active <= 1'b0;
                                            gate_mask <= 32'hffffffff;
                                        end else begin
                                            sweep_index <= sweep_index + 1'b1;
                                            sweep_on <= 1'b0;
                                            gate_mask <= ~(32'h00000001 << (sweep_index + 5'd1));
                                        end
                                    end else sweep_count <= sweep_count + 1'b1;
                                end
                            end
                        end
                    end

                    FADE_OUT: begin
                        // 准备在零增益边界取消时也必须走此出口；绝不回到TEST_IN。
                        if ((master_gain == 9'd0) || (ramp_step && (master_gain == 9'd1))) begin
                            master_gain <= 9'd0;
                            clear_audio <= 1'b1;
                            test_mode <= 1'b0;
                            gate_mask <= 32'd0;
                            requested_count <= 6'd0;
                            sweep_active <= 1'b0;
                            sweep_index <= 5'd0;
                            sweep_on <= 1'b0;
                            ramp_count <= 0;
                            state <= WAIT_RELEASE;
                        end else if (sample_tick) begin
                            if (ramp_step) begin
                                ramp_count <= 0;
                                master_gain <= master_gain - 1'b1;
                            end else ramp_count <= ramp_count + 1'b1;
                        end
                    end

                    WAIT_RELEASE: begin
                        // 继续拥有输出且保持数字零，直到整个键盘全松且无ghost。
                        // 来源改变已被消耗，不会在此等待或后续渐入中反复触发退出。
                        if (clean_release) begin
                            state <= FADE_NORMAL_IN;
                            ramp_count <= 0;
                        end
                    end

                    FADE_NORMAL_IN: begin
                        if (sample_tick) begin
                            if (ramp_step) begin
                                ramp_count <= 0;
                                if (master_gain >= 9'd255) begin
                                    master_gain <= 9'd256;
                                    state <= NORMAL;
                                    hold_count <= 0;
                                end else master_gain <= master_gain + 1'b1;
                            end else ramp_count <= ramp_count + 1'b1;
                        end
                    end

                    default: begin
                        // 非法状态采取退出路径，不直接在未知音量上切换引擎。
                        state <= FADE_OUT;
                        ramp_count <= 0;
                        sweep_active <= 1'b0;
                        controls_armed <= 1'b0;
                    end
                endcase
            end
        end
    end
endmodule
