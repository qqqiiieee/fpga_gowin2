// =============================================================================
// 共享波表合成器：生产为2音色、32复音，输出16位二补码PCM。
//
// 「音色」是不同的周期波形；「声部」是正在播放的一颗音符及其独立状态。
// NUM_TIMBRES种音色共享同一份ROM，32个声部各自保存相位、包络和上一帧门控。
// soft 层默认完整保存；生产实例可选经生成器验证的奇对称半表，容量减半。
// V008 的 color 恒为 0，另一半 bright 波形不会贡献声音，故可精确移除。
//
// clk=27 MHz；fs_tick 每 288 个 clk 到来一次，Fs=93750 Hz。
// 每个声部沿用 8 个时隙，最后经过 4 级有效标记流水线；32 声部约 261 clk
// 完成，必须早于下一次 fs_tick。保留调度时刻是为了维持帧中复触发的行为。
// rst_n 异步低有效；fs_tick 是 clk 域的一拍启动使能，不是另一时钟。
// gate/retrigger 每位对应一个声部；retrigger 在任意 clk 捕获并等该路时隙消费。
// note_bus/vel_bus/timbre_bus 从低位开始按声部 i 分别占 [i*7+:7]、
// [i*8+:8]、[i*TIMBRE_BITS+:TIMBRE_BITS]；音符用note_table编号，力度0..255。
// pitch 是 9 位有符号弯音码 [-256,255]，不是半音或 Hz；test_mode 选择测试正弦。
// sample 为 16 位二补码 PCM 位图；frame_done 在最后声部累加发布时脉冲一 clk。
// voice_busy 含释放尾音状态，voice_audible 仅表示包络非零；overrun 粘滞到复位。
// 参数默认 NUM_VOICES=32、TABLE_BITS=10：32 份相位/包络状态轮流用同一计算链。
// 不应把 NUM_VOICES 当作任意扩容参数：索引宽度、测试表 0..31 和帧预算须匹配。
// TABLE_BITS 决定演奏表每音色 2^TABLE_BITS 点；测试表固定 1024 点，当前按 10 配套。
// FILE/TEST_FILE 是 $readmemh 的演奏/测试 ROM 文本路径，默认值见参数声明。
// COMPACT_ROM 默认 0，兼容任意 FILE；1 使用 PACKED_FILE 中每音色原索引 0..511。
// 半表必须由 generate_odd_half_rom.py 验证完整原表后生成，不能仅将后半周取负。
// TIMBRE_BITS默认4以兼容历史独立测试；生产设1、NUM_TIMBRES=2，只保存1位音色。
// DUAL_PROFILE=1时0=原ID1柔和长笛、1=原ID7拨弦，保留原来的起音速度。
// =============================================================================
module wavetable_synth #(
    parameter NUM_VOICES=32,
    parameter TABLE_BITS=10,
    parameter TEST_FILE="src/test_sine.hex",
    parameter FILE="src/timbre_soft.hex",
    parameter COMPACT_ROM=0,
    parameter PACKED_FILE="src/timbre_odd_half.hex",
    parameter TIMBRE_BITS=4,
    parameter NUM_TIMBRES=(1<<TIMBRE_BITS),
    parameter DUAL_PROFILE=0,
    parameter PHASE_RAM=0, // 1: synchronous block RAM; 0: legacy observable phases[].
    parameter STATE_RAM=0, // 1: packed synchronous envelope/note state, same slot timing.
    parameter LIVE_ADSR_ENABLE=0, // 默认保持历史逐拍行为；生产实例显式设为1。
    parameter VISUAL_MONITOR_ENABLE=0 // 只读声部0/1，供李萨如；默认不增加观察寄存器。
)(
    input clk,input rst_n,input fs_tick,input test_mode,
    input [NUM_VOICES-1:0] gate,input [NUM_VOICES-1:0] retrigger,
    input [NUM_VOICES*7-1:0] note_bus,
    input [NUM_VOICES*8-1:0] vel_bus,
    input [NUM_VOICES*TIMBRE_BITS-1:0] timbre_bus,
    input signed [8:0] pitch,
    output reg [15:0] sample,output reg frame_done,output reg overrun,
    output [NUM_VOICES-1:0] voice_busy,
    output [NUM_VOICES-1:0] voice_audible,
    input [7:0] attack_ctrl,input [7:0] decay_ctrl,
    input [7:0] sustain_ctrl,input [7:0] release_ctrl,input [7:0] damping,
    output wire signed [15:0] monitor_voice0,monitor_voice1
);
    localparam IW=$clog2(NUM_VOICES);
    // 每 8 clk 最多注入一个样本，4 级流水线在 fs_tick 时最多残留一个。
    // 两次 fs_tick 之间最多累加 NUM_VOICES+1 项；组合 final_sum 再留一项。
    // 32 声部为 22 位，覆盖 34 * [-32768,32767]，也保留 overrun 行为。
    localparam MIX_BITS=16+$clog2(NUM_VOICES+2);
    localparam SCALE_BITS=MIX_BITS-2; // 正常模式至少右移 2 位，保留完整符号。
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
    reg [NUM_VOICES*TIMBRE_BITS-1:0] timbres_frame;
    reg signed [8:0] pitch_frame;
    reg [7:0] attack_frame,decay_frame,sustain_frame,release_frame,damping_frame;
    reg test_frame; // 与音符/门控同时冻结，单帧内不切换波形或频率。
    reg running;
    reg [IW-1:0] voice_index;
    reg [2:0] slot;

    // 单口同步 ROM：地址先寄存，下一个上升沿读取到 rom_q。
    // 高TIMBRE_BITS位选择音色，低TABLE_BITS位选择周期内位置。
    // 生产只有1位bank地址，避免16选1音色选择器和每声部4位快照。
    reg [TABLE_BITS+TIMBRE_BITS-1:0] rom_address,tone_address;
    // 额外一张1024点正弦ROM用于验证；地址仍由各路独立相位产生。
    // 和演奏波表并行读取，复用相同插值/包络/累加流水线，未另建32路引擎。
    reg [15:0] sine_rom[0:1023] /* synthesis syn_romstyle="block_rom" */;
    reg [15:0] sine_q;
    wire [15:0] rom_q;
    wire [15:0] waveform_q=test_frame?sine_q:rom_q;
    reg signed [15:0] soft_a,soft_b,soft_base,soft_interp;
    // 17 位差值 * 非负 8 位 frac，绝对值 <= 65535*255，25 位足够。
    reg signed [24:0] soft_product;
    reg [7:0] frac,env_slot;
    generate if(COMPACT_ROM) begin:compact_wave_rom
        // 对 idx>=512，原索引 -idx 的低 9 位是 (-idx_low9)&511。
        // 同一上升沿保存 ROM 读数和原 idx[9]；符号恢复不再增加寄存级。
        // 这保留 rom_q 的原单拍延迟，包括复位和帧中 test_frame 切换。
        reg [15:0] rom_half[0:(NUM_TIMBRES*(1<<(TABLE_BITS-1)))-1] /* synthesis syn_romstyle="block_rom" */;
        wire [TABLE_BITS-2:0] index_low=rom_address[TABLE_BITS-2:0];
        wire [TABLE_BITS-2:0] mirrored_low=-index_low;
        wire [TABLE_BITS-2:0] packed_index=rom_address[TABLE_BITS-1]?mirrored_low:index_low;
        wire [TABLE_BITS+TIMBRE_BITS-2:0] packed_address={rom_address[TABLE_BITS+TIMBRE_BITS-1:TABLE_BITS],packed_index};
        reg [15:0] packed_q;
        reg negate_q;
        initial $readmemh(PACKED_FILE,rom_half);
        always @(posedge clk) begin
            packed_q<=rom_half[packed_address];
            negate_q<=rom_address[TABLE_BITS-1];
        end
        assign rom_q=negate_q?(16'd0-packed_q):packed_q;
    end else begin:full_wave_rom
        // 默认支路完全不读取 PACKED_FILE，任意 16 位 FILE 样本都照原样播放。
        reg [15:0] rom[0:(NUM_TIMBRES*(1<<TABLE_BITS))-1] /* synthesis syn_romstyle="block_rom" */;
        reg [15:0] full_q;
        initial $readmemh(FILE,rom);
        always @(posedge clk) full_q<=rom[rom_address];
        assign rom_q=full_q;
    end endgenerate
    initial $readmemh(TEST_FILE,sine_rom);
    always @(posedge clk) begin
        sine_q<=sine_rom[rom_address[9:0]];
    end

    wire [6:0] selected_note=notes_frame[voice_index*7+:7];
    wire [7:0] velocity=velocities_frame[voice_index*8+:8];
    wire [TIMBRE_BITS-1:0] timbre=timbres_frame[voice_index*TIMBRE_BITS+:TIMBRE_BITS];
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
    // Slot 7 prefetches the following voice. A new fs_tick always fetches voice 0,
    // including an early tick that interrupts slot 0; the interrupted write is blocked.
    wire [23:0] current_phase;
    generate if(PHASE_RAM) begin:phase_ram
        reg [23:0] ram[0:NUM_VOICES-1] /* synthesis syn_ramstyle="block_ram" */;
        reg [23:0] read_q;
        reg [NUM_VOICES-1:0] phase_valid;
        reg read_valid_q;
        wire [IW-1:0] next_voice=(voice_index==NUM_VOICES-1)?{IW{1'b0}}:
                                 (voice_index+1'b1);
        wire [IW-1:0] read_address=fs_tick?{IW{1'b0}}:
                                  ((running && slot==7)?next_voice:voice_index);
        wire write_enable=rst_n && !fs_tick && running && slot==0;
        // No reset or clear on the storage or its synchronous data read register.
        // Raw uninitialised/stale data is masked until that voice has been written.
        always @(posedge clk) begin
            read_q<=ram[read_address];
            if(write_enable) ram[voice_index]<=current_phase+selected_increment;
        end
        // Only the 32-bit valid mask and the read-valid register reset asynchronously.
        // Read data and its validity always refer to the same sampled address.
        always @(posedge clk or negedge rst_n) begin
            if(!rst_n) begin phase_valid<=0;read_valid_q<=0;end
            else begin
                read_valid_q<=phase_valid[read_address];
                if(write_enable) phase_valid[voice_index]<=1'b1;
            end
        end
        assign current_phase=read_valid_q?read_q:24'd0;
    end else begin:phase_registers
        // Separate nonblocking process preserves the original reset/update timing
        // and keeps the top-level phases[] array available to old standalone tests.
        integer phase_i;
        always @(posedge clk or negedge rst_n) begin
            if(!rst_n) begin
                for(phase_i=0;phase_i<NUM_VOICES;phase_i=phase_i+1) phases[phase_i]<=0;
            end else if(!fs_tick && running && slot==0)
                phases[voice_index]<=current_phase+selected_increment;
        end
        assign current_phase=phases[voice_index];
    end endgenerate
    wire [7:0] current_env,sub;
    wire [2:0] current_state;
    wire [6:0] current_previous_note;
    wire [7:0] sustain=(velocity>>1)+(velocity>>2); // 约为力度的 3/4。
    // 重编号不能顺带改变ADSR：长笛1码/采样、拨弦8码/采样。
    // 历史默认分支供16音色独立回归使用，生产常量参数会消除该分支。
    wire [7:0] attack=DUAL_PROFILE ? (timbre==0 ? 8'd1 : 8'd8) :
                     ((timbre==0 || timbre==1 || timbre==8)?8'd1:
                     ((timbre==6 || timbre==7 || timbre==14)?8'd8:8'd3));
    reg [7:0] env_next;
    reg [2:0] state_next;

    // 实时ADSR用无符号Q8.12幅度（255.0为最大力度），整数部仍沿用envelopes[]。
    // 32声部只轮流使用下方一条加减/比较链；不是32套包络乘法器。
    // 小数部用同步RAM，无整RAM复位；只复位32位有效掩码，避免综合展开成复位FF。
    // 与相位RAM相同，在fs_tick/前一声部slot7预取，slot0写回，不增加8拍时隙。
    wire [11:0] live_fraction;
    reg [19:0] live_level_next;
    generate if(LIVE_ADSR_ENABLE) begin:live_envelope_ram
        reg [11:0] ram[0:NUM_VOICES-1] /* synthesis syn_ramstyle="block_ram" */;
        reg [11:0] read_q;
        reg [NUM_VOICES-1:0] valid;
        reg read_valid_q;
        wire [IW-1:0] next_voice=(voice_index==NUM_VOICES-1)?{IW{1'b0}}:
                                 (voice_index+1'b1);
        wire [IW-1:0] read_address=fs_tick?{IW{1'b0}}:
                                  ((running && slot==7)?next_voice:voice_index);
        wire write_enable=rst_n && !fs_tick && running && slot==0;
        always @(posedge clk) begin
            read_q<=ram[read_address];
            // 测试帧清小数部，但绝不改变旧整数包络/分频器规则。
            if(write_enable) ram[voice_index]<=test_frame?12'd0:live_level_next[11:0];
        end
        always @(posedge clk or negedge rst_n) begin
            if(!rst_n) begin valid<=0;read_valid_q<=0;end
            else begin
                read_valid_q<=valid[read_address];
                if(write_enable) valid[voice_index]<=1'b1;
            end
        end
        assign live_fraction=read_valid_q?read_q:12'd0;
    end else begin:no_live_envelope_ram
        assign live_fraction=12'd0;
    end endgenerate

    // A/D/R旋钮越大越慢，0最快、255最慢；每帧直接重算，按住音符也可编辑。
    // rate=max(1, ((31-(ctrl%16))*2048) >> (ctrl/16))，单位Q8.12码/音频帧。
    // 只有常量拼接/移位，没有运行时除法。低4位细调，高4位选择约2倍时间档。
    // Fs=93750Hz、力度255、幅度跨越0..255时，0为17帧≈0.181ms，255为
    // 1044480帧≈11.141s（另有触发/阶段转换的至多一帧延迟）。中间时间单调不减，
    // 极慢档受定点量化会有相邻旋钮码同速。低力度/较小幅度差按比例缩短；Release
    // 从松键当时的实际幅度下降，因此不是每次松键都固定走满上述全幅时间。
    function [15:0] live_rate;
        input [7:0] control;
        reg [15:0] shifted;
        begin
            shifted={1'b1,~control[3:0],11'b0} >> control[7:4];
            live_rate=(shifted==0)?16'd1:shifted;
        end
    endfunction
    wire [15:0] live_attack_rate=live_rate(attack_frame);
    wire [15:0] live_decay_rate=live_rate(decay_frame);
    wire [15:0] live_release_rate=live_rate(release_frame);
    // Sustain是力度峰值的比例，不是MIDI CC64延音踏板；本模块没有CC64输入。
    // floor(velocity*(S+1)/256)：S=0严格静音，S=255严格等于力度峰值。
    // 这一只8x9位乘法器由所有声部共用，PCM仍复用原来的有符号幅度乘法器。
    wire [8:0] live_sustain_gain={1'b0,sustain_frame}+9'd1;
    wire [16:0] live_sustain_product=velocity*live_sustain_gain;
    wire [19:0] live_target={live_sustain_product[15:8],12'd0};
    wire [19:0] live_peak={velocity,12'd0};
    wire [19:0] live_level={current_env,live_fraction};
    wire [20:0] live_rise={1'b0,live_level}+{5'd0,live_attack_rate};
    // FSR2仅对生产双音色的id1拨弦生效，id0长笛及历史16音色都不受影响。
    // 非零压力使Decay/Sustain音符进入不可自行回到Attack的Release；持续每帧额外减
    // damping*8个Q8.12码。值越大制音越快，不是只在压力边沿执行一次。
    // 例如R=255、峰值255时：压力0约11.14s，64约21.7ms，255约5.46ms。
    // 松开FSR只移除额外减量，Release/Idle不抬升；只有新NoteOn/重触发可再起音。
    // 新NoteOn独立开始Attack；Attack中只扣压力减量，仍允许新拨弦起音，再在
    // 到达峰值后进入受阻尼的Release。极慢Attack若小于压力减量会被直接闷住。
    wire live_damping_active=DUAL_PROFILE && timbre==1 && damping_frame!=0;
    wire [19:0] live_damping_step={9'd0,damping_frame,3'b0};
    wire [16:0] live_fall_rate={1'b0,live_release_rate}+
                             (live_damping_active?{6'd0,damping_frame,3'b0}:17'd0);
    wire note_start=selected_gate && (!previous_gates[voice_index] ||
                    selected_note!=current_previous_note || pending_triggers[voice_index]);

    // 持续音 ADSR：按下进入 attack，按住时 decay 到 sustain，松开才 release。
    // 复触发、门控从 0→1 或声部音符被替换，都会重新开始 attack。
    always @(*) begin
        env_next=current_env;state_next=current_state;
        live_level_next=live_level;
        if(selected_gate && (!previous_gates[voice_index] ||
           selected_note!=current_previous_note || pending_triggers[voice_index])) begin
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
        // test_frame无条件走上方冻结的历史ADSR，频率、正弦插值、PCM缩放也未改。
        // 参数为0时整个实时分支在展开时被消除，旧实例可不连接末尾新增端口。
        if(LIVE_ADSR_ENABLE && !test_frame) begin
            state_next=current_state;
            if(note_start) begin live_level_next=0;state_next=ATTACK;end
            else if(live_damping_active && current_state!=IDLE && current_state!=ATTACK) begin
                if(live_level<={3'd0,live_fall_rate}) begin
                    live_level_next=0;state_next=IDLE;
                end else begin
                    live_level_next=live_level-live_fall_rate;state_next=RELEASE;
                end
            end else case(current_state)
                IDLE:live_level_next=0;
                ATTACK:if(!selected_gate) state_next=RELEASE;
                    else begin
                        if(live_rise>={1'b0,live_peak}) begin
                            live_level_next=live_peak;state_next=DECAY;
                        end else live_level_next=live_rise[19:0];
                        // 不从零包络直接强制Release，否则持续任意非零FSR会吞掉
                        // 所有新NoteOn。只从本帧的Attack结果扣压力，运算链仍然共享。
                        if(live_damping_active) begin
                            if(live_level_next<=live_damping_step) begin
                                live_level_next=0;state_next=IDLE;
                            end else live_level_next=live_level_next-live_damping_step;
                        end
                    end
                DECAY,SUSTAIN:if(!selected_gate) state_next=RELEASE;
                    else if(live_level>live_target) begin
                        if(live_level-live_target<={4'd0,live_decay_rate}) begin
                            live_level_next=live_target;state_next=SUSTAIN;
                        end else live_level_next=live_level-live_decay_rate;
                    end else if(live_level<live_target) begin
                        // 实时调高S时也平滑上升；不能重新触发或重置DDS相位。
                        if(live_rise>={1'b0,live_target}) begin
                            live_level_next=live_target;state_next=SUSTAIN;
                        end else live_level_next=live_rise[19:0];
                    end else state_next=SUSTAIN;
                RELEASE:if(live_level<={3'd0,live_fall_rate}) begin
                        live_level_next=0;state_next=IDLE;
                    end else live_level_next=live_level-live_fall_rate;
                default:begin live_level_next=0;state_next=IDLE;end
            endcase
            env_next=live_level_next[19:12];
        end
    end

    // retrigger 可能只有一个 clk，先记住它，轮到该声部时消费。
    // 同一 clk 消费旧请求又收到新请求，OR 的新请求优先保留。
    wire [NUM_VOICES-1:0] consumed=(running && slot==0)?
        ({{(NUM_VOICES-1){1'b0}},1'b1}<<voice_index):0;
    always @(posedge clk or negedge rst_n)
        if(!rst_n) pending_triggers<=0;
        else pending_triggers<=(pending_triggers & ~consumed)|retrigger;
    // V041: 26 bits per voice share one synchronous BSRAM. Prefetch at frame
    // start / preceding slot7 makes the old value ready BEFORE slot0. No extra
    // stage is inserted into the eight-slot audio schedule, including early ticks.
    // Layout [25:18]=envelope, [17:10]=divider, [9:7]=state, [6:0]=last note.
    // RAM itself has no reset. A valid mask hides stale/uninitialised storage;
    // parallel 32-bit busy/audible mirrors preserve immediate per-voice observability.
    generate if(STATE_RAM) begin:packed_state_ram
        reg [25:0] ram[0:NUM_VOICES-1] /* synthesis syn_ramstyle="block_ram" */;
        reg [25:0] read_q;
        reg [NUM_VOICES-1:0] valid,busy_mirror,audible_mirror;
        reg read_valid_q;
        wire [IW-1:0] next_voice=(voice_index==NUM_VOICES-1)?{IW{1'b0}}:(voice_index+1'b1);
        wire [IW-1:0] read_address=fs_tick?{IW{1'b0}}:
            ((running && slot==7)?next_voice:voice_index);
        wire write_enable=rst_n && !fs_tick && running && slot==0;
        wire [7:0] next_sub=sub+8'd1;
        always @(posedge clk) begin
            read_q<=ram[read_address];
            if(write_enable)ram[voice_index]<={env_next,next_sub,state_next,selected_note};
        end
        always @(posedge clk or negedge rst_n) begin
            if(!rst_n)begin valid<=0;read_valid_q<=0;busy_mirror<=0;audible_mirror<=0;end
            else begin
                read_valid_q<=valid[read_address];
                if(write_enable)begin
                    valid[voice_index]<=1;
                    busy_mirror[voice_index]<=(state_next!=IDLE || env_next!=0);
                    audible_mirror[voice_index]<=(env_next!=0);
                end
            end
        end
        assign {current_env,sub,current_state,current_previous_note}=read_valid_q?read_q:26'd0;
        assign voice_busy=busy_mirror;
        assign voice_audible=audible_mirror;
    end else begin:legacy_state_registers
        integer state_i;
        always @(posedge clk or negedge rst_n) begin
            if(!rst_n)begin
                for(state_i=0;state_i<NUM_VOICES;state_i=state_i+1)begin
                    envelopes[state_i]<=0;subdivisions[state_i]<=0;
                    states[state_i]<=IDLE;previous_notes[state_i]<=0;
                end
            end else if(!fs_tick && running && slot==0)begin
                envelopes[voice_index]<=env_next;states[voice_index]<=state_next;
                subdivisions[voice_index]<=sub+1'b1;previous_notes[voice_index]<=selected_note;
            end
        end
        assign current_env=envelopes[voice_index];assign sub=subdivisions[voice_index];
        assign current_state=states[voice_index];assign current_previous_note=previous_notes[voice_index];
        for(genvar g=0;g<NUM_VOICES;g=g+1)begin:busy_flags
            assign voice_busy[g]=(states[g]!=IDLE || envelopes[g]!=0);
            assign voice_audible[g]=(envelopes[g]!=0);
        end
    end endgenerate

    // 线性插值：A + ((B-A)*frac >> 8)，frac 为 0..255 的小数权重。
    // 相邻点 B 的索引在当前音色内回绕，不能跳到下一种音色。
    wire signed [16:0] soft_difference=$signed(soft_b)-$signed(soft_a);
    wire signed [26:0] soft_result=$signed(soft_base)+(soft_product>>>8);
    reg v0,v1,v2,v3,last0,last1,last2,last3;
    reg signed [15:0] soft0,soft1,interp2,sample3;
    reg [7:0] env0,env1,env2;
    reg signed [MIX_BITS-1:0] accumulator;
    wire signed [24:0] amplitude_product=$signed(interp2)*$signed({1'b0,env2});
    wire signed [MIX_BITS-1:0] final_sum=accumulator+sample3;

    // V036只读观察：沿有效流水线传递声部0/1标签，锁存对应的包络后单路样本。
    // sample_tick读这两个保持值时，两路都已完成同一帧计算；它们位于混音/FX前。
    // 不复用最终左右声道（目前复制同一PCM），也不反向控制声音运算或帧调度。
    generate if(VISUAL_MONITOR_ENABLE)begin:visual_taps
        reg [1:0] tag0,tag1,tag2,tag3;
        reg signed [15:0] tap0,tap1;
        always @(posedge clk or negedge rst_n)begin
            if(!rst_n)begin tag0<=0;tag1<=0;tag2<=0;tag3<=0;tap0<=0;tap1<=0;end
            else begin
                tag1<=tag0;tag2<=tag1;tag3<=tag2;
                if(running && slot==7 && !fs_tick)
                    tag0<={(voice_index==1),(voice_index==0)};
                if(v3)begin
                    if(tag3[0])tap0<=sample3;
                    if(tag3[1])tap1<=sample3;
                end
            end
        end
        assign monitor_voice0=tap0;
        assign monitor_voice1=tap1;
    end else begin:no_visual_taps
        assign monitor_voice0=16'sd0;
        assign monitor_voice1=16'sd0;
    end endgenerate

    // 多声部先以较宽有符号数求和，避免 16 位相加直接溢出。
    // 沿用原版增益和软拐点：超过 16000 的幅度只增长 1/4，最终再限幅。
    // 这是幅度压缩，不是低通滤波，也不能消除 DAC 之后的模拟噪声。
    // 测试固定velocity=192，最大单路幅值<24576；32路最坏同相和
    // 再除64后<12288，低于满幅的一半。测试用线性缩放，避免软限幅谐波。
    wire signed [SCALE_BITS-1:0] scaled=test_frame?(final_sum>>>6):(final_sum>>>2);
    wire [SCALE_BITS-1:0] magnitude=scaled[SCALE_BITS-1]?-scaled:scaled;
    // 显式定宽常量，避免把限幅比较/减法重新扩成 32 位。
    localparam [SCALE_BITS-1:0] COMPRESS_KNEE=16000,PCM_LIMIT=32767;
    wire [SCALE_BITS-1:0] compressed=(magnitude>COMPRESS_KNEE)?
        (COMPRESS_KNEE+((magnitude-COMPRESS_KNEE)>>2)):magnitude;
    wire [15:0] bounded=compressed>PCM_LIMIT?16'd32767:compressed[15:0];
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            running<=0;slot<=0;voice_index<=0;sample<=0;frame_done<=0;overrun<=0;
            gates_frame<=0;notes_frame<=0;velocities_frame<=0;timbres_frame<=0;pitch_frame<=0;
            attack_frame<=0;decay_frame<=0;sustain_frame<=0;release_frame<=0;damping_frame<=0;
            test_frame<=0;previous_gates<=0;rom_address<=0;tone_address<=0;frac<=0;env_slot<=0;accumulator<=0;
            soft_a<=0;soft_b<=0;soft_base<=0;soft_interp<=0;soft_product<=0;
            v0<=0;v1<=0;v2<=0;v3<=0;last0<=0;last1<=0;last2<=0;last3<=0;
            soft0<=0;soft1<=0;interp2<=0;sample3<=0;env0<=0;env1<=0;env2<=0;
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
                    sample<=test_frame?scaled[15:0]:(scaled[SCALE_BITS-1]?-bounded:bounded);
                    frame_done<=1;
                end
            end
            if(fs_tick) begin
                // overrun 为粘滞诊断标志：一旦发现帧未算完，到复位才清除。
                if(running || v0 || v1 || v2 || v3) overrun<=1;
                gates_frame<=gate;notes_frame<=note_bus;velocities_frame<=vel_bus;
                timbres_frame<=timbre_bus;pitch_frame<=pitch;test_frame<=test_mode;
                if(LIVE_ADSR_ENABLE) begin
                    attack_frame<=attack_ctrl;decay_frame<=decay_ctrl;sustain_frame<=sustain_ctrl;
                    release_frame<=release_ctrl;damping_frame<=damping;
                end
                accumulator<=0;voice_index<=0;slot<=0;running<=1;
            end else if(running) begin
                slot<=slot+1'b1;
                case(slot)
                    0:begin
                        rom_address<={timbre,current_phase[23:24-TABLE_BITS]};
                        tone_address<={timbre,current_phase[23:24-TABLE_BITS]};
                        frac<=current_phase[23-TABLE_BITS:16-TABLE_BITS];env_slot<=env_next;
                        previous_gates[voice_index]<=selected_gate;
                    end
                    1:rom_address<={tone_address[TABLE_BITS+TIMBRE_BITS-1:TABLE_BITS],tone_address[TABLE_BITS-1:0]+1'b1};
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
