// =============================================================================
// 共享波表合成器：16 音色、32 复音，输出 16 位二补码 PCM。
//
// 「音色」是不同的周期波形；「声部」是正在播放的一颗音符及其独立状态。
// 16 种音色共享同一份 ROM，32 个声部各自保存相位、包络和上一帧门控。
// 本版只保留实际使用的 soft 层：16 * 1024 * 16 = 262144 bit。
// V008 的 color 恒为 0，另一半 bright 波形不会贡献声音，故可精确移除。
//
// clk=27 MHz；fs_tick 每 288 个 clk 到来一次，Fs=93750 Hz。
// 每个声部沿用 8 个时隙，最后经过 4 级有效标记流水线；32 声部约 261 clk
// 完成，必须早于下一次 fs_tick。保留调度时刻是为了维持帧中复触发的行为。
// rst_n 异步低有效；fs_tick 是 clk 域的一拍启动使能，不是另一时钟。
// gate/retrigger 每位对应一个声部；retrigger 在任意 clk 捕获并等该路时隙消费。
// note_bus/vel_bus/timbre_bus 从低位开始按声部 i 分别占 [i*7+:7]、
// [i*8+:8]、[i*4+:4]；音符用 note_table 编号，力度 0..255，音色 0..15。
// pitch 是 9 位有符号弯音码 [-256,255]，不是半音或 Hz；test_mode 选择测试正弦。
// sample 为 16 位二补码 PCM 位图；frame_done 在最后声部累加发布时脉冲一 clk。
// voice_busy 含释放尾音状态，voice_audible 仅表示包络非零；overrun 粘滞到复位。
// 参数默认 NUM_VOICES=32、TABLE_BITS=10：32 份相位/包络状态轮流用同一计算链。
// 不应把 NUM_VOICES 当作任意扩容参数：索引宽度、测试表 0..31 和帧预算须匹配。
// TABLE_BITS 决定演奏表每音色 2^TABLE_BITS 点；测试表固定 1024 点，当前按 10 配套。
// FILE/TEST_FILE 是 $readmemh 的演奏/测试 ROM 文本路径，默认值见参数声明。
// =============================================================================
module wavetable_synth #(
    parameter NUM_VOICES=32,
    parameter TABLE_BITS=10,
    parameter TEST_FILE="src/test_sine.hex",
    parameter FILE="src/timbre_soft.hex"
)(
    input clk,input rst_n,input fs_tick,input test_mode,
    input [NUM_VOICES-1:0] gate,input [NUM_VOICES-1:0] retrigger,
    input [NUM_VOICES*7-1:0] note_bus,
    input [NUM_VOICES*8-1:0] vel_bus,
    input [NUM_VOICES*4-1:0] timbre_bus,
    input signed [8:0] pitch,
    output reg [15:0] sample,output reg frame_done,output reg overrun,
    output [NUM_VOICES-1:0] voice_busy,
    output [NUM_VOICES-1:0] voice_audible
);
    localparam IW=$clog2(NUM_VOICES);
    localparam IDLE=0,ATTACK=1,DECAY=2,SUSTAIN=3,RELEASE=4;

    // 各声部独立状态。24 位 DDS 相位自然溢出，实现一个周期的循环。
    // subdivision 是包络的分频计数，和相位不同，不用于计算音高。
    reg [23:0] phases[0:NUM_VOICES-1];
    reg [7:0] envelopes[0:NUM_VOICES-1];
    reg [7:0] subdivisions[0:NUM_VOICES-1];
    reg [2:0] states[0:NUM_VOICES-1];
    reg [6:0] previous_notes[0:NUM_VOICES-1];
    reg [NUM_VOICES-1:0] previous_gates,pending_triggers;

    // 在采样边界冻结输入，使一帧内的所有声部使用同一批音符/力度/音色。
    reg [NUM_VOICES-1:0] gates_frame;
    reg [NUM_VOICES*7-1:0] notes_frame;
    reg [NUM_VOICES*8-1:0] velocities_frame;
    reg [NUM_VOICES*4-1:0] timbres_frame;
    reg signed [8:0] pitch_frame;
    reg test_frame; // 与音符/门控同时冻结，单帧内不切换波形或频率。
    reg running;
    reg [IW-1:0] voice_index;
    reg [2:0] slot;

    // 单口同步 ROM：地址先寄存，下一个上升沿读取到 rom_q。
    // 高 4 位选择音色，低 TABLE_BITS 位选择周期内位置。
    reg [15:0] rom[0:(16*(1<<TABLE_BITS))-1] /* synthesis syn_romstyle="block_rom" */;
    reg [TABLE_BITS+3:0] rom_address,tone_address;
    // 额外一张1024点正弦ROM用于验证；地址仍由各路独立相位产生。
    // 和演奏波表并行读取，复用相同插值/包络/累加流水线，未另建32路引擎。
    reg [15:0] sine_rom[0:1023] /* synthesis syn_romstyle="block_rom" */;
    reg [15:0] sine_q;
    reg [15:0] rom_q;
    wire [15:0] waveform_q=test_frame?sine_q:rom_q;
    reg signed [15:0] soft_a,soft_b,soft_base,soft_interp;
    reg signed [25:0] soft_product;
    reg [7:0] frac,env_slot;
    initial $readmemh(FILE,rom);
    initial $readmemh(TEST_FILE,sine_rom);
    always @(posedge clk) begin
        rom_q<=rom[rom_address];
        sine_q<=sine_rom[rom_address[9:0]];
    end

    wire [6:0] selected_note=notes_frame[voice_index*7+:7];
    wire [7:0] velocity=velocities_frame[voice_index*8+:8];
    wire [3:0] timbre=timbres_frame[voice_index*4+:4];
    wire selected_gate=gates_frame[voice_index];
    wire [23:0] increment;
    note_table frequency(selected_note,increment);

    // 滑音保持原有近似公式：inc' = inc + floor(inc/2048)*pitch。
    // pitch 是有符号码值，不是 Hz 或半音；负数降低频率，正数升高频率。
    wire signed [13:0] bend_base=$signed({1'b0,increment[23:11]});
    wire signed [22:0] bend_delta=bend_base*pitch_frame;
    wire [23:0] bent_increment=increment+{bend_delta[22],bend_delta};
    wire [23:0] test_increment;
    wire [4:0] test_voice_index=voice_index;
    oscillator_test_frequencies test_frequency(test_voice_index,test_increment);
    wire [23:0] selected_increment=test_frame?test_increment:bent_increment;
    wire [23:0] current_phase=phases[voice_index];
    wire [7:0] current_env=envelopes[voice_index];
    wire [2:0] current_state=states[voice_index];
    wire [7:0] sub=subdivisions[voice_index];
    wire [7:0] sustain=(velocity>>1)+(velocity>>2); // 约为力度的 3/4。
    wire [7:0] attack=(timbre==0 || timbre==1 || timbre==8)?1:
                     ((timbre==6 || timbre==7 || timbre==14)?8:3);
    reg [7:0] env_next;
    reg [2:0] state_next;

    // 持续音 ADSR：按下进入 attack，按住时 decay 到 sustain，松开才 release。
    // 复触发、门控从 0→1 或声部音符被替换，都会重新开始 attack。
    always @(*) begin
        env_next=current_env;state_next=current_state;
        if(selected_gate && (!previous_gates[voice_index] ||
           selected_note!=previous_notes[voice_index] || pending_triggers[voice_index])) begin
            env_next=0;state_next=ATTACK;
        end else case(current_state)
            IDLE:env_next=0;
            ATTACK:if(!selected_gate) state_next=RELEASE;
                else if({1'b0,current_env}+{1'b0,attack}>={1'b0,velocity}) begin
                    env_next=velocity;state_next=DECAY;
                end else env_next=current_env+attack;
            DECAY:if(!selected_gate) state_next=RELEASE;
                else if(sub[1:0]==3) begin
                    if(current_env<=sustain+1'b1) state_next=SUSTAIN;
                    else env_next=current_env-1'b1;
                end
            SUSTAIN:if(!selected_gate) state_next=RELEASE;
            RELEASE:if(sub[3:0]==15) begin
                if(current_env<=1) begin env_next=0;state_next=IDLE;end
                else env_next=current_env-1'b1;
            end
            default:begin env_next=0;state_next=IDLE;end
        endcase
    end

    // retrigger 可能只有一个 clk，先记住它，轮到该声部时消费。
    // 同一 clk 消费旧请求又收到新请求，OR 的新请求优先保留。
    wire [NUM_VOICES-1:0] consumed=(running && slot==0)?
        ({{(NUM_VOICES-1){1'b0}},1'b1}<<voice_index):0;
    always @(posedge clk or negedge rst_n)
        if(!rst_n) pending_triggers<=0;
        else pending_triggers<=(pending_triggers & ~consumed)|retrigger;
    genvar g;
    generate for(g=0;g<NUM_VOICES;g=g+1) begin:busy_flags
        // 松键后包络仍可能有尾音，不能立即把声部当作完全空闲。
        assign voice_busy[g]=(states[g]!=IDLE || envelopes[g]!=0);
        // 数字活跃表示该路包络非零，不等同于经过声卡实测的可闻谱峰。
        assign voice_audible[g]=(envelopes[g]!=0);
    end endgenerate

    // 线性插值：A + ((B-A)*frac >> 8)，frac 为 0..255 的小数权重。
    // 相邻点 B 的索引在当前音色内回绕，不能跳到下一种音色。
    wire signed [16:0] soft_difference=$signed(soft_b)-$signed(soft_a);
    wire signed [26:0] soft_result=$signed(soft_base)+(soft_product>>>8);
    reg v0,v1,v2,v3,last0,last1,last2,last3;
    reg signed [15:0] soft0,soft1,interp2,sample3;
    reg [7:0] env0,env1,env2;
    reg signed [27:0] accumulator;
    wire signed [24:0] amplitude_product=$signed(interp2)*$signed({1'b0,env2});
    wire signed [27:0] final_sum=accumulator+sample3;

    // 多声部先以较宽有符号数求和，避免 16 位相加直接溢出。
    // 沿用原版增益和软拐点：超过 16000 的幅度只增长 1/4，最终再限幅。
    // 这是幅度压缩，不是低通滤波，也不能消除 DAC 之后的模拟噪声。
    // 测试固定velocity=192，最大单路幅值<24576；32路最坏同相和
    // 再除64后<12288，低于满幅的一半。测试用线性缩放，避免软限幅谐波。
    wire signed [27:0] scaled=test_frame?(final_sum>>>6):(final_sum>>>2);
    wire [27:0] magnitude=scaled[27]?-scaled:scaled;
    wire [27:0] compressed=(magnitude>16000)?
        (28'd16000+((magnitude-16000)>>2)):magnitude;
    wire [15:0] bounded=compressed>32767?16'd32767:compressed[15:0];
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            running<=0;slot<=0;voice_index<=0;sample<=0;frame_done<=0;overrun<=0;
            gates_frame<=0;notes_frame<=0;velocities_frame<=0;timbres_frame<=0;pitch_frame<=0;
            test_frame<=0;previous_gates<=0;rom_address<=0;tone_address<=0;frac<=0;env_slot<=0;accumulator<=0;
            soft_a<=0;soft_b<=0;soft_base<=0;soft_interp<=0;soft_product<=0;
            v0<=0;v1<=0;v2<=0;v3<=0;last0<=0;last1<=0;last2<=0;last3<=0;
            soft0<=0;soft1<=0;interp2<=0;sample3<=0;env0<=0;env1<=0;env2<=0;
            for(i=0;i<NUM_VOICES;i=i+1) begin
                phases[i]<=0;envelopes[i]<=0;subdivisions[i]<=0;
                states[i]<=IDLE;previous_notes[i]<=0;
            end
        end else begin
            // valid/last 和对应数据一同传递，最后一个声部落地才发布 PCM。
            frame_done<=0;v0<=0;v1<=v0;v2<=v1;v3<=v2;
            last1<=last0;last2<=last1;last3<=last2;
            if(v0) begin soft1<=soft0;env1<=env0;end
            if(v1) begin interp2<=soft1;env2<=env1;end
            if(v2) sample3<=amplitude_product>>>8;
            if(v3) begin
                accumulator<=final_sum;
                if(last3) begin
                    sample<=test_frame?scaled[15:0]:(scaled[27]?-bounded:bounded);
                    frame_done<=1;
                end
            end
            if(fs_tick) begin
                // overrun 为粘滞诊断标志：一旦发现帧未算完，到复位才清除。
                if(running || v0 || v1 || v2 || v3) overrun<=1;
                gates_frame<=gate;notes_frame<=note_bus;velocities_frame<=vel_bus;
                timbres_frame<=timbre_bus;pitch_frame<=pitch;test_frame<=test_mode;
                accumulator<=0;voice_index<=0;slot<=0;running<=1;
            end else if(running) begin
                slot<=slot+1'b1;
                case(slot)
                    0:begin
                        rom_address<={timbre,current_phase[23:24-TABLE_BITS]};
                        tone_address<={timbre,current_phase[23:24-TABLE_BITS]};
                        frac<=current_phase[23-TABLE_BITS:16-TABLE_BITS];env_slot<=env_next;
                        phases[voice_index]<=current_phase+selected_increment;
                        envelopes[voice_index]<=env_next;states[voice_index]<=state_next;
                        subdivisions[voice_index]<=sub+1'b1;
                        previous_gates[voice_index]<=selected_gate;
                        previous_notes[voice_index]<=selected_note;
                    end
                    1:rom_address<={tone_address[TABLE_BITS+3:TABLE_BITS],tone_address[TABLE_BITS-1:0]+1'b1};
                    2:soft_a<=$signed(waveform_q);
                    3:soft_b<=$signed(waveform_q);
                    4:begin soft_base<=soft_a;soft_product<=soft_difference*$signed({1'b0,frac});end
                    5:soft_interp<=soft_result[15:0];
                    // 时隙 6 有意留作调度间隔，不再读取或计算 bright 波形。
                    // 保留八时隙顺序，避免删掉空隙后改变声部相位/复触发消费时刻。
                    6:begin end
                    7:begin
                        soft0<=soft_interp;env0<=env_slot;v0<=1;
                        last0<=(voice_index==NUM_VOICES-1);
                        if(voice_index==NUM_VOICES-1) running<=0;
                        else voice_index<=voice_index+1'b1;
                    end
                endcase
            end
        end
    end
endmodule
