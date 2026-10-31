// 声音层：声部分配→波表旋律→MIDI双鼓混音→去直流→FSR明亮度/可选低通→音量→PT8211。
// PRESSURE_EXPRESSION_ENABLE1时pressure_brightness(0..255)连续开合低通，ready0回退原低通。
// 所有寄存器使用 27MHz clk；fs_tick/frame_done 是时钟使能，不是新时钟。
// 输出是板载 3.5mm 耳机链路，不驱动外部 MAX98357。
// rst_n 异步低有效；test_clear 同 clk 脉冲组合生成音频局部复位，不停 PT8211。
// note_on/off、hit0/1是clk域事件；note为7位编号，力度0..255，生产音色0/1。
// 外部timbre保留4位通信接口；生产0长笛、1拨弦，其他码回退0。
// slider_volume 为0..255无单位控制码，slider_pitch 为9位有符号弯音码。
// test_gate_mask 每位对应声部，test_master_gain 为0..256的Q8倍率。
// LOWPASS_ENABLE 默认1（0旁路、非0允许），还受 filter_enable 运行开关控制。
// NUM_VOICES 默认32，改变时须同时满足合成器索引、测试表和每帧288 clk预算。
// monitor_pcm 是16位二补码耳机装载字，monitor_tick 是 PT8211 整帧装载使能。
// 此 tick 同时启动下一轮合成；frame_done 是计算结果发布事件，不等于装载事件。
// monitor_busy 每位含 gate/包络忙，monitor_test_busy 是测试非零包络掩码；
// 这些数字状态不证明外部模拟输出可闻。overrun 是合成器的粘滞超时标志。
// TRANSITION_INPUT_ENABLE默认0兼容旧独立调用；生产顶层为1并连控制器的normal_input_ready。
module instrument_audio #(parameter LOWPASS_ENABLE=1,parameter NUM_VOICES=32,
    parameter TRANSITION_INPUT_ENABLE=0,parameter REDUCED_TIMBRES=0,
    parameter SOURCE_TAG_ENABLE=0,parameter PHASE_RAM=0,parameter PRESSURE_EXPRESSION_ENABLE=0,
    parameter CONTROL_BANK_ENABLE=0,parameter LIVE_ADSR_ENABLE=0,parameter EFFECTS_ENABLE=0,
    parameter VISUAL_MONITOR_ENABLE=0)(
    input clk,input rst_n,input note_on,input note_off,input [6:0] note,
    input [7:0] velocity,input [3:0] timbre,
    input [7:0] slider_volume,input signed [8:0] slider_pitch,
    input hit0,input hit1,input [7:0] velocity0,input [7:0] velocity1,
    input digital_zero_test,input filter_enable,
    input test_owned,input test_mode,input test_clear,
    input normal_input_ready,
    input [NUM_VOICES-1:0] test_gate_mask,input [8:0] test_master_gain,
    output hp_bck,output hp_ws,output hp_din,output overrun,
    output monitor_tick,output [15:0] monitor_pcm,
    output signed [8:0] monitor_pitch,output [NUM_VOICES-1:0] monitor_busy,
    output [NUM_VOICES-1:0] monitor_test_busy,
    input [1:0] event_source,
    input [7:0] pressure_brightness,input pressure_brightness_ready,
    input [7:0] attack_ctrl,decay_ctrl,sustain_ctrl,release_ctrl,damping,mix_balance,
    input hat_closed_hit,hat_open_hit,input [7:0] hat_closed_velocity,hat_open_velocity,
    input [1:0] fx_mode,input [7:0] fx_amount,fx_time,fx_feedback,fx_mod,
    output signed [15:0] monitor_voice0,monitor_voice1
);
    wire fs_tick,frame_done;
    wire [NUM_VOICES-1:0] gate,retrigger,voice_busy,voice_audible;
    wire [NUM_VOICES*7-1:0] note_bus;
    wire [NUM_VOICES*8-1:0] vel_bus;
    // 兼容的4位外部编号在入口收敛为1位；无效编号回到长笛，不能访问越界ROM。
    // REDUCED_TIMBRES默认0供旧音频对照使用，生产顶层明确设置1。
    localparam TIMBRE_BITS=REDUCED_TIMBRES?1:4;
    wire [TIMBRE_BITS-1:0] allocated_timbre=REDUCED_TIMBRES?(timbre==4'd1):timbre;
    wire [NUM_VOICES*TIMBRE_BITS-1:0] timbre_bus;
    wire signed [8:0] pitch_smooth;
    wire [15:0] mixed,kick_sample,snare_sample,mix_sample;
    wire [15:0] dc_sample,clean_sample,sample;
    wire kick_busy,snare_busy;
    wire [15:0] closed_hat_sample,open_hat_sample,effected_sample;
    wire closed_hat_busy,open_hat_busy,fx_tail_busy;
    // 只复位声音状态，不停止PT8211位时钟，也不复位ADC、串口或HDMI。
    // 控制器在淡出到零后发同clk域clear脉冲，防止测试音/旧尾音互相残留。
    wire audio_rst_n=rst_n && !test_clear;
    // 恢复普通演奏的21.845ms渐入仍owned，但不能消费并丢弃键盘一次性事件。
    // 入口淡出/测试/等待全松仍拒绝普通事件；不用test_mode反推交接阶段。
    wire accept_normal_input=TRANSITION_INPUT_ENABLE ? normal_input_ready : !test_owned;
    // test_owned 为控制器所有权状态；test_mode 才决定使用哪组波形/门控。
    // 正常音符事件是否接受按下方使能条件决定，32路测试仍使用同一个合成器。
    // 常数力度192经过各路独立ADSR，不能用直接混合32路预录PCM替代。
    wire [NUM_VOICES-1:0] synth_gate=test_mode?test_gate_mask:gate;
    wire [NUM_VOICES-1:0] synth_retrigger=test_mode?{NUM_VOICES{1'b0}}:retrigger;
    wire [NUM_VOICES*8-1:0] synth_velocity=test_mode?{NUM_VOICES{8'd192}}:vel_bus;
    wire [NUM_VOICES*TIMBRE_BITS-1:0] synth_timbre=test_mode?{NUM_VOICES*TIMBRE_BITS{1'b0}}:timbre_bus;
    // 暂存演奏控制目标；测试期间实体滑杆仍可采集，但不调制测试频率/音量。
    reg [7:0] saved_volume;
    reg signed [8:0] saved_pitch;
    always @(posedge clk or negedge rst_n)
        if(!rst_n) begin saved_volume<=160;saved_pitch<=0;end
        else if(!test_owned) begin saved_volume<=slider_volume;saved_pitch<=slider_pitch;end
    voice_allocator #(.NUM_VOICES(NUM_VOICES),.ONE_SHOT_GATES(0),.TIMBRE_BITS(TIMBRE_BITS),
        .SOURCE_TAG_ENABLE(SOURCE_TAG_ENABLE)) u_alloc(
        .clk(clk),.rst_n(audio_rst_n),.fs_tick(fs_tick),
        .note_on(note_on && accept_normal_input),.note_off(note_off && accept_normal_input),
        .note(note),.velocity(velocity),.timbre(allocated_timbre),.voice_busy(voice_busy),
        .gate(gate),.retrigger(retrigger),.note_bus(note_bus),.vel_bus(vel_bus),.timbre_bus(timbre_bus),
        .event_source(event_source));
    // 生产波表已由生成器逐样本验证奇对称，使用每音色原始前 512 点。
    // wavetable_synth 的默认值仍为 0，独立调用及任意 FILE 不受此选择影响。
    // 生产仅实例化2x512点半表；原16音色表只作冻结基准，不占用生产ROM。
    wavetable_synth #(.NUM_VOICES(NUM_VOICES),.COMPACT_ROM(1),
        .PHASE_RAM(PHASE_RAM),.STATE_RAM(PHASE_RAM),
        .LIVE_ADSR_ENABLE(LIVE_ADSR_ENABLE),
        .VISUAL_MONITOR_ENABLE(VISUAL_MONITOR_ENABLE),
        .TIMBRE_BITS(TIMBRE_BITS),.NUM_TIMBRES(REDUCED_TIMBRES?2:16),
        .DUAL_PROFILE(REDUCED_TIMBRES),
        .FILE(REDUCED_TIMBRES?"src/timbre_dual.hex":"src/timbre_soft.hex"),
        // 两分支路径长度相同：旧Icarus会把较短字符串分支左补0，导致readmemh失败。
        // 重复目录分隔符与单个含义相同，不复制资产、不改变任何ROM内容或生产路径。
        .PACKED_FILE(REDUCED_TIMBRES?"src/timbre_dual_half.hex":"src//timbre_odd_half.hex")) synth(
        .clk(clk),.rst_n(audio_rst_n),.fs_tick(fs_tick),.test_mode(test_mode),
        .gate(synth_gate),.retrigger(synth_retrigger),
        .note_bus(note_bus),.vel_bus(synth_velocity),.timbre_bus(synth_timbre),
        .pitch(test_mode?9'sd0:pitch_smooth),
        .sample(mixed),.frame_done(frame_done),.overrun(overrun),
        .voice_busy(voice_busy),.voice_audible(voice_audible),
        .attack_ctrl(attack_ctrl),.decay_ctrl(decay_ctrl),.sustain_ctrl(sustain_ctrl),
        .release_ctrl(release_ctrl),.damping(damping),
        .monitor_voice0(monitor_voice0),.monitor_voice1(monitor_voice1));
    drum_voice kick(.clk(clk),.rst_n(audio_rst_n),.fs_tick(fs_tick),
        .clear(digital_zero_test || test_mode),
        .hit(hit0 && accept_normal_input),.velocity(velocity0),.sample(kick_sample),.busy(kick_busy));
    snare_voice snare(.clk(clk),.rst_n(audio_rst_n),.fs_tick(fs_tick),
        .clear(digital_zero_test || test_mode),
        .hit(hit1 && accept_normal_input),.velocity(velocity1),.sample(snare_sample),.busy(snare_busy));
    generate if(CONTROL_BANK_ENABLE) begin:production_mixing
      hat_voice #(.OPEN(0)) closed_hat(.clk(clk),.rst_n(audio_rst_n),.fs_tick(fs_tick),
        .clear(digital_zero_test || test_mode),.hit(hat_closed_hit && accept_normal_input),
        .velocity(hat_closed_velocity),.sample(closed_hat_sample),.busy(closed_hat_busy));
      hat_voice #(.OPEN(1)) open_hat(.clk(clk),.rst_n(audio_rst_n),.fs_tick(fs_tick),
        .clear(digital_zero_test || test_mode),.hit(hat_open_hit && accept_normal_input),
        .velocity(hat_open_velocity),.sample(open_hat_sample),.busy(open_hat_busy));
      performance_mixer mixer(.clk(clk),.rst_n(audio_rst_n),.tick(frame_done),
        .melody(mixed),.kick(kick_sample),.snare(snare_sample),
        .closed_hat(closed_hat_sample),.open_hat(open_hat_sample),.balance(mix_balance),.sample(mix_sample));
    end else begin:legacy_mixing
      assign closed_hat_sample=0;assign open_hat_sample=0;
      assign closed_hat_busy=0;assign open_hat_busy=0;
      audio_mix mixer(.melody(mixed),.kick(kick_sample),.snare(snare_sample),.sample(mix_sample));
    end endgenerate

    // quiet 等待旋律尾音和鼓衰减结束，再等待 128 个采样帧。
    // 不能只看松键，否则会截断尾音并产生突变声。
    reg [7:0] idle_frames;
    reg quiet;
    wire sound_active=(|synth_gate) || (|voice_busy) ||
        (accept_normal_input && (note_on || hit0 || hit1 ||
          (CONTROL_BANK_ENABLE && (hat_closed_hit || hat_open_hit)))) ||
        kick_busy || snare_busy || closed_hat_busy || open_hat_busy;
    always @(posedge clk or negedge audio_rst_n) begin
        if(!audio_rst_n) begin idle_frames<=128;quiet<=1;end
        else if(sound_active) begin idle_frames<=0;quiet<=0;end
        else if(fs_tick) begin
            if(idle_frames<128) idle_frames<=idle_frames+1'b1;
            if(idle_frames>=127) quiet<=1;
        end
    end
    // frame_done 表示旋律 PCM 算完。保留原寄存器延迟和非阻塞赋值顺序：
    // 每级在上升沿读取的是上一个 clk 的上级输出，不是同一沿的新值。
    dc_blocker dc(.clk(clk),.rst_n(audio_rst_n && !quiet),.tick(frame_done),
        .sample_in(mix_sample),.sample_out(dc_sample));
    audio_cleanup #(.LOWPASS_ENABLE(LOWPASS_ENABLE),.EXPRESSION_ENABLE(PRESSURE_EXPRESSION_ENABLE)) cleanup(.clk(clk),.rst_n(audio_rst_n),
        .tick(frame_done),.quiet(quiet),.enable(filter_enable),
        .sample_in(dc_sample),.sample_out(clean_sample),
        .expression(pressure_brightness),.expression_ready(pressure_brightness_ready));
    generate if(EFFECTS_ENABLE) begin:global_effects
      // 效果尾音属于发声结果，不能在主声部quiet时立刻截断；测试/数字零才清缓存元数据。
      audio_effects fx(.clk(clk),.rst_n(audio_rst_n),.tick(frame_done),
        .clear(digital_zero_test || test_mode),.input_active(sound_active || !quiet),
        .mode(fx_mode),.amount(fx_amount),.time_control(fx_time),
        .feedback_control(fx_feedback),.mod_control(fx_mod),.sample_in(clean_sample),
        .sample_out(effected_sample),.tail_busy(fx_tail_busy));
    end else begin:no_effects
      assign effected_sample=clean_sample;assign fx_tail_busy=0;
    end endgenerate
    audio_controls controls(.clk(clk),.rst_n(audio_rst_n),.fs_tick(fs_tick),
        .sample_in(effected_sample),.volume(test_owned?saved_volume:slider_volume),
        .pitch_in(test_owned?saved_pitch:slider_pitch),
        .pitch_smooth(pitch_smooth),.sample_out(sample));
    // 空闲/诊断强制送数字零；DAC、耳机模拟级和电脑输入仍可能产生噪声。
    // 测试正弦仍经同一PT8211串行器/DAC输出。只在验证模式选择线性测试PCM，
    // 避开双鼓混音、软限幅后的演奏滤波/音量通路，减少额外谱峰和幅度变化。
    wire [15:0] normal_sample=(quiet && !fx_tail_busy)?16'd0:sample;
    wire [15:0] mode_sample=test_mode?mixed:normal_sample;
    // 9位gain可表示256，乘法前补0成正的10位，防止256被当作负数。
    wire signed [25:0] faded=$signed(mode_sample)*$signed({1'b0,test_master_gain});
    wire [15:0] faded_sample=faded>>>8;
    wire [15:0] headphone_sample=digital_zero_test?16'd0:
        (test_owned?faded_sample:normal_sample);
    pt8211_driver u_pt8211(.clk(clk),.rst_n(rst_n),.sample(headphone_sample),
        .bck(hp_bck),.ws(hp_ws),.din(hp_din),.fs_tick(fs_tick));
// 采样时刻与PT8211装载时刻一致，不读取串行DIN来反推波形。
    assign monitor_tick=fs_tick;
    assign monitor_pcm=headphone_sample;
    assign monitor_pitch=test_mode?9'sd0:pitch_smooth;
    assign monitor_busy=voice_busy | gate;
    // 这是数字非零包络状态；真正可闻32谱峰由外部声卡频谱验证。
    assign monitor_test_busy=(test_mode && test_master_gain!=0)?voice_audible:0;
endmodule
