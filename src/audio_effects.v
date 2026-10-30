`timescale 1ns/1ps
// ================= 中文阅读与集成约定 =================
// 这是总混音之后共用的单声道数字效果器；不能给每个声部分别实例化。
// 全部时序均使用 27 MHz clk，tick 是 93750 Hz 的单拍使能，不是新时钟。
// 采样在 tick=1 的上升沿锁存；运算最迟第50 clk完成，统一第63 clk发布。
// 独立参考回归测得：旁路1、Delay29、Chorus33、Reverb50 clk；发布延迟
// 63/27=2.333333 us，距下次288 clk的tick尚余225 clk。无外部done端口。
// frame_done 可接 tick；调用方须在发布点之后消费 sample_out，并保留尾音
// 期间的 clk/tick。digital_zero/test_mode 可接 clear；测试声旁路由主层选择。
//
// 【接口与优先级】
// rst_n：异步低有效，仅复位控制寄存器，绝不擦除 RAM。
// clear：同步高有效，优先于 tick、读写流程和第63 clk发布；当拍输出为0，
//        中止运算、使全部历史失效，重新锁存当前模式/参数作为起点。
// mode：0旁路、1延迟、2合唱、3混响。amount=0 或 mode=0 的当帧输出，
//       必须等于该 tick 锁存的 sample_in，仅附加固定63 clk延迟。
// input_active：主声部活动提示；0不能切掉干声、停止反馈或清除效果尾音。
// 非零PCM同样重新激活尾音。tail_busy 供主层 quiet 门控，与主声部busy合用。
// tail_busy 在旁路/amount0时为0；其余保守保留最长回声间隔，再判断结束。
// time_control控制Delay长度、Chorus基准延迟和Reverb房间尺寸。
// feedback_control控制Delay/Reverb反馈；mod_control控制Chorus的速率/深度，
// 在Delay/Reverb中保留。Chorus速率约0.179..3.029Hz，深度0..510采样。
// 控制变化先按每tick一码平滑；Delay/Chorus的基准延迟另限速1/8采样/tick。
// 切换模式先把旧湿声淡到0，再使历史整体失效，接入新模式后淡入；新模式
// 未填充的延迟区读作0。请求可连续改变，真正接入时取最新mode。
//
// 【定点与饱和】
// sample_in/out、RAM字：有符号16位PCM。内部tap/wet/全通中间值18位。
// 四路梳状之和也用18位，边界为-131072，不能先在18位内取正幅度再移位。
// 唯一通用乘法器：有符号18位乘无符号8位，26位累加；8次移位加法，
// 反馈只需4次。没有 RTL 乘号运算符，不要求DSP。Q8除256，Q4除16。
// q8_zero/q4_zero/half_zero：算术右移后，负数有非零余数时补1，向0舍入；
// 防止负数-1反复反馈形成直流极限环，也覆盖最小负数。写RAM与最终输出
// 均显式饱和到[-32768,32767]，保留完整干声后再叠加湿声，不发生回绕。
// amount满量程=255/256湿声；Delay反馈上限14/16，Reverb反馈为8..14/16。
// Chorus延迟以Q14.8表示，LFO三角波为16位；相邻两点按8位小数线性插值。
// delay_q共22位；乘法product共26位。LFO相位24位，溢出自然回卷。
//
// 【RAM布局与失效机制】
// 唯一 history[0:16383] 为16384x16=262144 bit=32 KiB，所有模式复用。
// Delay/Chorus：整个14位环形地址空间；Delay最大15304点，插值额外读1点。
// Reverb：梳状0/1/2/3位于0/2048/4096/6144，每区2048字；全通0/1位于
//         8192/9216，每区1024字。高位分区、低位环形减法，避免可变取模。
// write_ptr每音频帧推进一次；sample_ptr锁存当前写位；fill_count记录历史
// 帧数，valid_count锁存此前已写好帧数作为本帧读资格。每个tap分别检查fill>=延迟，
// 插值第二个tap必须检查fill>=延迟+1。复位/clear/接入新模式只清元数据，
// 未写区及旧尾音即使仍在物理RAM里，也不能进入反馈或输出。
// 主声部安静后继续运算。湿声连续16384帧仅剩0/1 LSB才允许自然失效；
// 不会把长Delay中间的空隙误判为尾音结束。另设750000帧=8秒硬上限，
// 最后256帧淡出，再失效；重新输入活动或非零PCM会重置这个计时。
//
// 【Gowin综合检查建议；本任务没有运行综合】
// 估计以16块1024x18的18Kb BSRAM串深实现，物理294912bit，低于24块预算。
// 这是布局估计，不能代替Gowin映射报告；CLS占用和27MHz时序均尚未实测。
// 必须保留下面独立的同步读/同步写RAM进程，不要给数组加复位、for清零、
// 异步读或逐字复位，也不要把各模式复制成多份数组。确认工具推断为块RAM
// 而非寄存器/LUT RAM；若需显式SDPB/DPB或属性，应由主agent结合映射报告处理。
// 读写带独立地址/使能，无有效tap同址碰撞依赖；读数据寄存器不复位。
// 乘法使用共享串行状态，检查没有意外DSP；不要把表达式改回组合乘法。
// =====================================================
// Shared mono effects, clk=27 MHz, tick=93,750 Hz (288 clocks/sample).
// Signed PCM16 in/out. Accept tick only when idle; publish at tick+63 clk,
// including bypass/amount=0 (bit-exact dry). clear aborts even a pending publish.
// No top-level/audio integration, vendor primitive, DSP or RAM reset is needed.
//
// RAM: ONE synchronous-read simple-dual-port 16,384 x 16 array = 262,144 bits.
// Estimated Gowin mapping: 16 x (1024 x 18) BSRAM, not a synthesis result.
// Shared between modes, NOT 16 blocks per effect. Never reset/clear this array.
// fill_count/valid_count mask every unfilled tap, including interpolation's
// second tap. Mode adoption/clear/expired tails invalidate the entire history.
//
// Controls (all sampled on tick):
// amount: dry + wet * gain/256, gain slews 1/sample; amount=0 overrides at once.
// time: Delay 1024+56*time samples (10.923..163.243 ms), fractional tap slew
//       <=1/8 sample/tick. Chorus base 768+8*time (also slewed <=1/8),
//       depth <=510 samples.
//       Reverb comb lengths {701,907,1151,1277}+3*time; AP {113,337}+time/2.
// feedback: Delay min(14,control/16)/16; Reverb min(14,8+control/32)/16.
//           Integer division truncates towards ZERO, preventing negative DC
//           limit cycles. Both feedback gains <=7/8. Chorus has no feedback.
// mod: Chorus triangle-LFO rate (32+2*mod)*93750/2^24 Hz (0.179..3.029 Hz),
//      depth mod*2 samples. Linear interpolation uses 8 fractional tap bits.
//      In Delay/Reverb mod is reserved; other parameters slew 1 code/sample.
// Reverb: FOUR parallel combs, averaged, then TWO Schroeder allpasses g=1/2;
//         each comb receives dry/2. These are separate feedback paths, not echo.
// Mode requests fade old wet gain to zero, invalidate, adopt latest mode, then
// fade in. mode=0 is immediate dry, even while the internal fade completes.
//
// input_active is only an activity hint, NEVER a tail-clear or input gate.
// Nonzero PCM also arms/rearms tails. tail_busy is conservative: gaps shorter
// than a whole RAM (174.763 ms) cannot end a tail. Below-2-LSB wet for that long
// invalidates history. A hard 8-second inactivity limit fades the final 256
// samples then invalidates, even if parameters create an unusually long tail.
// Keep tick/clk running until !tail_busy; clear before test-owned bypass.
module audio_effects (
    input wire clk, rst_n, tick, clear, input_active,
    input wire [1:0] mode,
    input wire [7:0] amount, time_control, feedback_control, mod_control,
    input wire signed [15:0] sample_in,
    output reg signed [15:0] sample_out,
    output reg tail_busy
);
    // 750000个音频采样，固定生产上限；测试不会缩短它。
    localparam [19:0] TAIL_MAX_SAMPLES = 20'd750000;
    localparam [5:0] S_IDLE=0, S_DRY=1, S_TAP_REQ=2, S_TAP_WAIT=3,
        S_TAP_FIRST=4, S_TAP_SECOND=5, S_INTERP=6, S_DELAY_FB=7,
        S_DELAY_WRITE=8, S_COMB_REQ=9, S_COMB_WAIT=10, S_COMB_USE=11,
        S_COMB_WRITE=12, S_AP_REQ=13, S_AP_WAIT=14, S_AP_USE=15,
        S_AP_WRITE=16, S_MIX=17, S_MIX_DONE=18, S_DONE=19,
        S_LFO_DONE=20, S_MUL=21;

    // Intentionally no initial block, reset, clear, or for loop for memory.
    // RAM只允许下方时钟进程访问；控制复位永远不接触数组内容。
    reg signed [15:0] history [0:16383];
    reg [13:0] ram_raddr, ram_waddr;
    reg ram_re, ram_we;
    reg signed [15:0] ram_rdata, ram_wdata;
    always @(posedge clk) begin
        if (ram_we) history[ram_waddr] <= ram_wdata;
        if (ram_re) ram_rdata <= history[ram_raddr];
    end

    // 状态/乘法返回状态/固定发布倒计时，均属于同一个clk域。
    reg [5:0] state, mul_return, clocks_left;
    reg busy, result_ready, force_dry;
    reg [1:0] active_mode;
    reg [7:0] wet_gain, time_smooth, feedback_smooth, mod_smooth, gain_latched;
    reg [13:0] write_ptr, sample_ptr;
    reg [14:0] fill_count, valid_count, quiet_samples;
    reg [19:0] idle_samples;
    reg tail_armed;
    reg signed [15:0] dry, result_pcm;
    reg signed [17:0] wet, last_wet, first_tap, second_tap;
    reg [21:0] delay_q;
    reg [23:0] lfo_phase;
    reg [13:0] tap_length;
    reg [7:0] tap_fraction;
    reg [3:0] feedback_q4;
    reg [1:0] comb_index;
    reg ap_index;
    reg signed [17:0] comb_sum, ap_input;
    reg signed [15:0] ap_delayed;

    // The ONLY general product datapath: 8 serial shift/add steps (4 for Q4).
    // Signed 18 x unsigned 8 fits signed 26, including interpolation delta.
    reg signed [25:0] mul_a, mul_acc, product;
    reg [7:0] mul_b;
    reg [3:0] mul_steps;
    wire signed [25:0] mul_next = mul_acc + (mul_b[0] ? mul_a : 26'sd0);
    // 延迟Q8目标：1024*256+time*56*256；Chorus基准为(768+8*time)*256。
    wire [21:0] delay_target = active_mode==2 ?
        22'd196608 + ({14'd0,time_smooth} << 11) :
        22'd262144 + ({14'd0,time_smooth} << 14) - ({14'd0,time_smooth} << 11);
    wire [15:0] triangle = lfo_phase[23] ? ~lfo_phase[22:7] : lfo_phase[22:7];
    wire signed [17:0] triangle_signed = $signed({2'b00,triangle}) - 18'sd32768;
    // LFO乘积右移6后仍是Q8采样单位，峰值深度约2*mod个采样。
    wire signed [25:0] chorus_q = $signed({4'd0,delay_q}) + (product >>> 6);
    wire [10:0] comb_delay = (comb_index==0 ? 11'd701 :
        comb_index==1 ? 11'd907 : comb_index==2 ? 11'd1151 : 11'd1277)
        + {3'd0,time_smooth} + ({3'd0,time_smooth} << 1);
    wire [9:0] ap_delay = (ap_index ? 10'd337 : 10'd113) + {3'd0,time_smooth[7:1]};
    wire [10:0] comb_offset = sample_ptr[10:0] - comb_delay;
    wire [9:0] ap_offset = sample_ptr[9:0] - ap_delay;
    wire signed [17:0] dry_wide = {{2{dry[15]}},dry};

    // 19位加法结果先比较上下限，最后才截为16位，避免溢出回绕。
    function signed [15:0] saturate;
        input signed [18:0] value;
        begin
            if (value > 19'sd32767) saturate=16'sh7fff;
            else if (value < -19'sd32768) saturate=16'sh8000;
            else saturate=value[15:0];
        end
    endfunction
    // 算术移位是向负无穷取整；对负数非零余数补1才得到向0取整。
    function signed [17:0] q8_zero;
        input signed [25:0] value;
        begin q8_zero = (value >>> 8) +
            ((value[25] && (|value[7:0])) ? 26'sd1 : 26'sd0); end
    endfunction
    function signed [17:0] q4_zero;
        input signed [25:0] value;
        begin q4_zero = (value >>> 4) +
            ((value[25] && (|value[3:0])) ? 26'sd1 : 26'sd0); end
    endfunction
    function signed [17:0] half_zero;
        input signed [17:0] value;
        // No magnitude negation: the sum of four -32768 comb taps can be
        // -131072, whose positive magnitude does not fit signed 18 bits.
        begin half_zero = (value >>> 1) +
            ((value[17] && value[0]) ? 18'sd1 : 18'sd0); end
    endfunction
    function [7:0] slew;
        input [7:0] current_value, target_value;
        begin
            if (current_value < target_value) slew=current_value+8'd1;
            else if (current_value > target_value) slew=current_value-8'd1;
            else slew=current_value;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=S_IDLE; mul_return<=S_IDLE; busy<=0; clocks_left<=0;
            result_ready<=0; force_dry<=1; active_mode<=0; sample_out<=0;
            tail_busy<=0; tail_armed<=0; idle_samples<=0; quiet_samples<=0;
            wet_gain<=0; gain_latched<=0; time_smooth<=0; feedback_smooth<=0;
            mod_smooth<=0; write_ptr<=0; sample_ptr<=0; fill_count<=0;
            valid_count<=0; dry<=0; result_pcm<=0; wet<=0; last_wet<=0;
            first_tap<=0; second_tap<=0; delay_q<=22'd262144; lfo_phase<=0;
            tap_length<=0; tap_fraction<=0; feedback_q4<=0;
            comb_index<=0; comb_sum<=0; ap_index<=0; ap_input<=0; ap_delayed<=0;
            mul_a<=0; mul_acc<=0; mul_b<=0; product<=0; mul_steps<=0;
            ram_re<=0; ram_we<=0; ram_raddr<=0; ram_waddr<=0; ram_wdata<=0;
        end else if (clear) begin
            // Does not touch history or ram_rdata. Stale pending writes are
            // harmless: future reads remain masked until overwritten.
            state<=S_IDLE; busy<=0; clocks_left<=0; result_ready<=0;
            sample_out<=0; force_dry<=1; active_mode<=mode; wet_gain<=0;
            gain_latched<=0; time_smooth<=time_control;
            feedback_smooth<=feedback_control; mod_smooth<=mod_control;
            write_ptr<=0; sample_ptr<=0; fill_count<=0; valid_count<=0;
            tail_busy<=0; tail_armed<=0; idle_samples<=0; quiet_samples<=0;
            dry<=0; result_pcm<=0; wet<=0; last_wet<=0; lfo_phase<=0;
            delay_q<=mode==2 ? 22'd196608 + ({14'd0,time_control} << 11) :
                22'd262144 + ({14'd0,time_control} << 14) - ({14'd0,time_control} << 11);
            ram_re<=0; ram_we<=0;
        end else begin
            ram_re<=0; ram_we<=0;
            // 接受新帧：锁存干声、湿声增益及历史读资格，启动对应串行流程。
            if (tick && !busy) begin
                busy<=1; clocks_left<=6'd63; result_ready<=0;
                dry<=sample_in; force_dry<=(mode==0 || amount==0);
                time_smooth<=slew(time_smooth,time_control);
                feedback_smooth<=slew(feedback_smooth,feedback_control);
                mod_smooth<=slew(mod_smooth,mod_control);
                gain_latched<=wet_gain;
                if (mode!=active_mode ||
                    (tail_armed && idle_samples>=TAIL_MAX_SAMPLES-20'd256))
                    wet_gain<=slew(wet_gain,0);
                else wet_gain<=slew(wet_gain,amount);
                if (delay_q < delay_target)
                    delay_q<=delay_target-delay_q < 22'd32 ? delay_target : delay_q+22'd32;
                else if (delay_q > delay_target)
                    delay_q<=delay_q-delay_target < 22'd32 ? delay_target : delay_q-22'd32;
                lfo_phase<=lfo_phase + 24'd32 + ({16'd0,mod_smooth} << 1);
                feedback_q4<=active_mode==3 ?
                    (feedback_smooth[7:5]>=6 ? 4'd14 : 4'd8+{1'b0,feedback_smooth[7:5]}) :
                    (feedback_smooth[7:4]>14 ? 4'd14 : feedback_smooth[7:4]);

                // 活动只重置尾音计时；非活动时仍继续RAM读写与反馈运算。
                if (input_active || sample_in!=0) begin
                    idle_samples<=0; quiet_samples<=0;
                    tail_armed<=(active_mode!=0 && mode!=0 && amount!=0);
                end else begin
                    if (idle_samples<TAIL_MAX_SAMPLES) idle_samples<=idle_samples+20'd1;
                    if (last_wet>18'sd1 || last_wet < -18'sd1) quiet_samples<=0;
                    else if (quiet_samples<15'd16384) quiet_samples<=quiet_samples+15'd1;
                end
                tail_busy<=(mode!=0 && amount!=0 &&
                    (input_active || sample_in!=0 || tail_armed));

                // 淡出完成接入新模式，或尾音到期：只开启新的历史epoch。
                if ((mode!=active_mode && wet_gain==0) ||
                    (tail_armed && !input_active && sample_in==0 &&
                     (idle_samples>=TAIL_MAX_SAMPLES-1 || quiet_samples>=15'd16384))) begin
                    // New epoch: invalidate every partition simultaneously.
                    fill_count<=0; write_ptr<=0; last_wet<=0; tail_armed<=0;
                    tail_busy<=0; active_mode<=mode; wet_gain<=0;
                    lfo_phase<=0; idle_samples<=0; quiet_samples<=0;
                    delay_q<=mode==2 ? 22'd196608 + ({14'd0,time_smooth} << 11) :
                        22'd262144 + ({14'd0,time_smooth} << 14) - ({14'd0,time_smooth} << 11);
                    state<=S_DRY;
                end else if (active_mode==0) begin
                    state<=S_DRY; last_wet<=0;
                end else begin
                    sample_ptr<=write_ptr; write_ptr<=write_ptr+14'd1;
                    valid_count<=fill_count;
                    if (fill_count<15'd16384) fill_count<=fill_count+15'd1;
                    if (active_mode==3) begin
                        comb_index<=0; comb_sum<=0; state<=S_COMB_REQ;
                    end else if (active_mode==2) begin
                        mul_a<={{8{triangle_signed[17]}},triangle_signed};
                        mul_b<=mod_smooth; mul_acc<=0; mul_steps<=8;
                        mul_return<=S_LFO_DONE; state<=S_MUL;
                    end else begin
                        tap_length<=delay_q[21:8]; tap_fraction<=delay_q[7:0];
                        state<=S_TAP_REQ;
                    end
                end
            end else if (busy) begin
                clocks_left<=clocks_left-6'd1;
                // 提前完成也等到同一发布边沿；clear分支优先于此处。
                if (clocks_left==1) begin
                    sample_out<=force_dry ? dry : result_pcm;
                    busy<=0; state<=S_IDLE;
                end else case (state)
                    // 纯干声/切换失效帧；同样等待第63 clk发布。
                    S_DRY: begin result_pcm<=dry; result_ready<=1; state<=S_DONE; end
                    // LFO深度乘法完成，将Q8延迟拆成整数tap和小数权重。
                    S_LFO_DONE: begin
                        tap_length<=chorus_q[21:8]; tap_fraction<=chorus_q[7:0];
                        state<=S_TAP_REQ;
                    end
                    // 两次同步RAM读：先D点，再D+1点；WAIT负责RAM一拍延迟。
                    S_TAP_REQ: begin
                        ram_raddr<=sample_ptr-tap_length; ram_re<=1;
                        state<=S_TAP_WAIT;
                    end
                    S_TAP_WAIT: begin
                        ram_raddr<=sample_ptr-tap_length-14'd1; ram_re<=1;
                        state<=S_TAP_FIRST;
                    end
                    S_TAP_FIRST: begin
                        first_tap<=valid_count>={1'b0,tap_length} ?
                            {{2{ram_rdata[15]}},ram_rdata} : 18'sd0;
                        state<=S_TAP_SECOND;
                    end
                    // 即使D点有效，D+1点仍可能未写，必须独立屏蔽。
                    S_TAP_SECOND: begin
                        // Interpolate d[n-D]*(1-f) + d[n-D-1]*f.
                        second_tap<=valid_count>={1'b0,tap_length}+15'd1 ?
                            {{2{ram_rdata[15]}},ram_rdata} : 18'sd0;
                        mul_a<=valid_count>={1'b0,tap_length}+15'd1 ?
                            $signed(ram_rdata)-first_tap : -first_tap;
                        mul_b<=tap_fraction; mul_acc<=0; mul_steps<=8;
                        mul_return<=S_INTERP; state<=S_MUL;
                    end
                    // wet=a+trunc((b-a)*fraction/256)，保留有符号插值。
                    S_INTERP: begin
                        wet<=first_tap+q8_zero(product);
                        state<=active_mode==1 ? S_DELAY_FB : S_DELAY_WRITE;
                    end
                    // Delay回授湿声*Q4反馈；Chorus直接写原始干声，没有反馈。
                    S_DELAY_FB: begin
                        mul_a<={{8{wet[17]}},wet}; mul_b<={4'd0,feedback_q4};
                        mul_acc<=0; mul_steps<=4;
                        mul_return<=S_DELAY_WRITE; state<=S_MUL;
                    end
                    S_DELAY_WRITE: begin
                        ram_waddr<=sample_ptr; ram_we<=1;
                        ram_wdata<=active_mode==1 ?
                            saturate(dry_wide+q4_zero(product)) : dry;
                        state<=S_MIX;
                    end
                    // 四条梳状串行复用同一RAM端口和Q4乘法器，每条8 clk。
                    S_COMB_REQ: begin
                        ram_raddr<={1'b0,comb_index,comb_offset}; ram_re<=1;
                        state<=S_COMB_WAIT;
                    end
                    S_COMB_WAIT: state<=S_COMB_USE;
                    S_COMB_USE: begin
                        first_tap<=valid_count>={4'd0,comb_delay} ?
                            {{2{ram_rdata[15]}},ram_rdata} : 18'sd0;
                        mul_a<=valid_count>={4'd0,comb_delay} ?
                            {{10{ram_rdata[15]}},ram_rdata} : 26'sd0;
                        mul_b<={4'd0,feedback_q4}; mul_acc<=0; mul_steps<=4;
                        mul_return<=S_COMB_WRITE; state<=S_MUL;
                    end
                    // c_i[n]=sat(dry/2+g*c_i[n-D_i])；平均四路后送入扩散。
                    S_COMB_WRITE: begin
                        ram_waddr<={1'b0,comb_index,sample_ptr[10:0]}; ram_we<=1;
                        ram_wdata<=saturate(half_zero(dry_wide)+q4_zero(product));
                        comb_sum<=comb_sum+first_tap;
                        if (comb_index==3) begin
                            // Arithmetic average; sign-symmetric rounding.
                            ap_input<=half_zero(half_zero(comb_sum+first_tap));
                            ap_index<=0; state<=S_AP_REQ;
                        end else begin comb_index<=comb_index+2'd1; state<=S_COMB_REQ; end
                    end
                    // 两级全通各4 clk，g=1/2，真正形成多路径扩散。
                    S_AP_REQ: begin
                        ram_raddr<=14'd8192 + (ap_index ? 14'd1024 : 14'd0)
                            + {4'd0,ap_offset};
                        ram_re<=1; state<=S_AP_WAIT;
                    end
                    S_AP_WAIT: state<=S_AP_USE;
                    S_AP_USE: begin
                        first_tap<=valid_count>={5'd0,ap_delay} ?
                            {{2{ram_rdata[15]}},ram_rdata} : 18'sd0;
                        ap_delayed<=valid_count>={5'd0,ap_delay} ? ram_rdata : 16'sd0;
                        state<=S_AP_WRITE;
                    end
                    // v=sat(x+z/2)，y=z-v/2；输出必须使用实际饱和写入的v。
                    S_AP_WRITE: begin
                        // v=x+g*z; y=z-g*v, g=1/2. Saturate stored v, then
                        // use that SAME v in y so finite-word feedback agrees.
                        ram_waddr<=14'd8192 + (ap_index ? 14'd1024 : 14'd0)
                            + {4'd0,sample_ptr[9:0]};
                        ram_wdata<=saturate(ap_input+half_zero(first_tap)); ram_we<=1;
                        if (!ap_index) begin
                            ap_input<=$signed(ap_delayed)-half_zero(
                                $signed(saturate(ap_input+half_zero(first_tap))));
                            ap_index<=1; state<=S_AP_REQ;
                        end else begin
                            wet<=$signed(ap_delayed)-half_zero(
                                $signed(saturate(ap_input+half_zero(first_tap))));
                            state<=S_MIX;
                        end
                    end
                    // 保留全量dry；唯一Q8乘法器计算wet*平滑amount，最后统一饱和。
                    S_MIX: begin
                        last_wet<=wet;
                        mul_a<={{8{wet[17]}},wet}; mul_b<=gain_latched;
                        mul_acc<=0; mul_steps<=8; mul_return<=S_MIX_DONE; state<=S_MUL;
                    end
                    S_MIX_DONE: begin
                        result_pcm<=saturate(dry_wide+q8_zero(product));
                        result_ready<=1; state<=S_DONE;
                    end
                    // 共享有符号移位加法：每clk处理一个系数位，末拍跳回调用状态。
                    S_MUL: begin
                        mul_acc<=mul_next; mul_a<=mul_a <<< 1; mul_b<=mul_b >> 1;
                        mul_steps<=mul_steps-4'd1;
                        if (mul_steps==1) begin product<=mul_next; state<=mul_return; end
                    end
                    default: ;
                endcase
            end
        end
    end
endmodule
