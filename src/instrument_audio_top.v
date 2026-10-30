// Tang Primer 20K 顶层：端口、上电复位及三层连接，不在这里实现状态机。
// 输入层：键盘/ADS1115/UART；声音层：32复音/MIDI双鼓/滤波表情/耳机；状态层：LED/组合键。
// PRESSURE_EXPRESSION_ENABLE=1时FSR A0明亮度/A1揉弦，0保留历史鼓输入供对照。
// monitor_expression0/1是平滑后0..255控制量，不是kg；calibrated两位为对应通道标定状态。
// clk=27MHz H11。VIRTUAL_ADC_CYCLES 是虚拟 ADC 节奏，不是音频采样率。
// 无外部复位口；寄存器初值和 por_cnt 产生配置后低有效复位，再按 clk 同步释放。
// monitor_rst_n 是此源域复位；monitor_tick 为93750Hz整帧装载使能，不是新时钟。
// matrix_rows 为逐行0/Z，matrix_cols低有效需上拉；ADC为开漏I2C，UART为8N1。
// hp_bck/ws/din 保留 PT8211 右对齐；amp_* 为PCM5102A标准I2S，pa_en 固定1。
// monitor_pcm为16位二补码装载字；keys bit0..15为S1..S16，timbre为0长笛/1拨弦，
// volume为0..255控制码，pitch为9位有符号弯音码；busy每位对应声部0..31。
// monitor_adc低到高四个16位原始码为A0/A1压力、A2音量、A3保留；V021不使用A3，原始码不是kg。
// monitor_flags bit7..0依次为overrun/ghost/input_ready/adc_stale/adc_fault/
// filter_enable/remote_active/digital_zero；ready 不表示完成传感器物理标定。
// test_gate/busy每位对应测试声部；requested为请求数0/1/4/8/16/32，index为0..31。
// 测试owned与test_mode为持续状态，监视口没有额外valid，不由HDMI消费来反控音频。
// LOWPASS_ENABLE 默认1，按布尔开关使用；VIRTUAL_ADC_CYCLES 默认63390，
// 须在1..65536内匹配虚拟计数器。TEST_* 默认187500/5625000/46875/8，
// 单位为采样数，范围/非正值处理继承 oscillator_test_control。
module instrument_audio_top #(parameter LOWPASS_ENABLE=1,parameter VIRTUAL_ADC_CYCLES=63390,
    parameter TOUCH_ENABLE=0,parameter PRESSURE_EXPRESSION_ENABLE=0,
    parameter MIDI_ENABLE=0,parameter OPTICAL_ENABLE=0,parameter MIDI_CHANNEL=0,parameter PHASE_RAM=0,
    parameter DISPLAY_TOUCH_ONLY=0,parameter LIVE_ADSR_ENABLE=0,parameter EFFECTS_ENABLE=0,
    parameter TEST_HOLD_SAMPLES=187500,parameter TEST_MAX_SAMPLES=5625000,
    parameter TEST_SWEEP_HALF_SAMPLES=46875,parameter TEST_RAMP_DIV=8)(
    input clk,output [3:0] matrix_rows,input [3:0] matrix_cols,
    inout adc_scl,inout adc_sda,input uart_rx,output uart_tx,
    output hp_bck,output hp_ws,output hp_din,output pa_en,
    output amp_bck,output amp_lrc,output amp_din,output [3:0] timbre_led_n,
    output monitor_rst_n,output monitor_tick,output [15:0] monitor_pcm,
    output [15:0] monitor_keys,output [3:0] monitor_timbre,output [7:0] monitor_volume,
    output signed [8:0] monitor_pitch,output [31:0] monitor_busy,
    output [7:0] monitor_flags,output [63:0] monitor_adc,
    output monitor_test_owned,output monitor_test_mode,
    output [31:0] monitor_test_gate,output [31:0] monitor_test_busy,
    output [5:0] monitor_test_requested,output monitor_test_sweep,
    output [4:0] monitor_test_index,
    output touch_cs_n,output touch_sclk,output touch_mosi,input touch_miso,
    input midi_rx,input [1:0] optical_beams,
    output [11:0] monitor_performance_keys,output [6:0] monitor_external_note,
    output monitor_external_note_valid,
    output [7:0] monitor_expression0,output [7:0] monitor_expression1,
    output [1:0] monitor_pressure_calibrated,
    input [15:0] ui_test_keys,input ui_panic,input ui_strum_mode,
    input ui_timbre_set_valid,input [3:0] ui_timbre_set_value,
    input ui_filter_enable,input ui_zero_mode,input [1:0] control_page,input ui_fx_cycle,
    output [1:0] monitor_fx_mode,output [31:0] monitor_knob_values,
    input phone_set_valid,input [7:0] phone_param,phone_value,phone_query_param,
    output [7:0] phone_query_value,output [13:0] monitor_external_diagnostic,
    // 源域只读显示支路，bit0=MIDI48、bit31=MIDI79；不反馈演奏或声音路径。
    output [31:0] monitor_piano_keys32,output monitor_piano_outside);
    // 配置后先保持复位 256 个主时钟，待状态确定后才允许工作。
    reg [7:0] por_cnt=0;reg rst_n=0;
    always @(posedge clk) begin
        if(por_cnt!=255) por_cnt<=por_cnt+1'b1;
        rst_n<=(por_cnt==255);
    end
    wire note_on,note_off,hit0,hit1;
    wire input_ready,input_remote;
    wire [6:0] note;
    wire [7:0] velocity,velocity0,velocity1,slider_volume;
    wire [3:0] timbre,selected_timbre;wire [15:0] key_state;
    wire signed [8:0] slider_pitch;
    wire keypad_ghost,digital_zero_test,adc_fault,adc_stale,filter_enable,overrun;
    wire input_filter_enable,status_filter_enable;
    // V021菜单与旧组合键状态各自驱动独立线，再按生产模式唯一选择，不能并联输出。
    assign filter_enable=DISPLAY_TOUCH_ONLY?input_filter_enable:status_filter_enable;
    wire test_owned,test_mode,test_clear,test_sweep;
    wire [31:0] test_gate;
    wire [5:0] test_requested;
    wire [4:0] test_index;
    wire [8:0] test_gain;
    wire [3:0] test_state;
    wire normal_input_ready;
    wire [1:0] note_source;
    wire panic_audio;
    wire hat_closed_hit,hat_open_hit;
    wire [7:0] hat_closed_velocity,hat_open_velocity;
    wire [7:0] mix_balance,brightness_base,attack_ctrl,decay_ctrl,sustain_ctrl,release_ctrl;
    wire [7:0] fx_amount,fx_time,fx_feedback,fx_mod;
    reg panic_test_mute;
    wire touch_calibrating,touch_diagnostic_pulse;
    // 测试期间所有全局Panic（含MIDI故障/CC120）和校准均请求安全退出，
    // 不能只复位声音后让仍为1的test_gate重新起音。
    wire abort_test=DISPLAY_TOUCH_ONLY && test_owned &&
       (ui_panic || panic_audio || touch_diagnostic_pulse);
    wire resume_normal=normal_input_ready && !test_mode;
    // 渐入第一拍就解除硬静音，保留test_gain的正常淡入；不吞掉该拍新Pad。
    wire effective_test_mute=abort_test || (panic_test_mute && !resume_normal);
    always @(posedge clk or negedge rst_n)
      if(!rst_n)panic_test_mute<=0;
      else if(abort_test)panic_test_mute<=1;
      else if(resume_normal)panic_test_mute<=0;
    // Panic在测试中立即静音并请求正常退出；不等待淡出期间继续播放测试正弦。
    wire [15:0] test_control_keys=DISPLAY_TOUCH_ONLY?
       (abort_test?16'h8000:ui_test_keys):key_state;
    // 本地长按/串口虚拟键都使用同一已消抖key_state，避免矩阵鬼键绕过。
    // 默认计数按93750Hz；参数只为仿真加速提供覆盖，不改变板上时钟。
    oscillator_test_control #(.HOLD_SAMPLES(TEST_HOLD_SAMPLES),.MAX_SAMPLES(TEST_MAX_SAMPLES),
        .SWEEP_HALF_SAMPLES(TEST_SWEEP_HALF_SAMPLES),.RAMP_DIV(TEST_RAMP_DIV)) test_control(
        .clk(clk),.rst_n(rst_n),.sample_tick(monitor_tick),.keys(test_control_keys),
        .ghost(abort_test?1'b0:keypad_ghost),.remote_active(input_remote),.owned(test_owned),
        .test_mode(test_mode),.gate_mask(test_gate),.requested_count(test_requested),
        .sweep_active(test_sweep),.sweep_index(test_index),.master_gain(test_gain),
        .clear_audio(test_clear),.state_debug(test_state),.normal_input_ready(normal_input_ready));
    instrument_inputs #(.VIRTUAL_ADC_CYCLES(VIRTUAL_ADC_CYCLES),.TOUCH_ENABLE(TOUCH_ENABLE),
        .PRESSURE_EXPRESSION_ENABLE(PRESSURE_EXPRESSION_ENABLE),
        .DISPLAY_TOUCH_ONLY(DISPLAY_TOUCH_ONLY),
        .MIDI_ENABLE(MIDI_ENABLE),.OPTICAL_ENABLE(OPTICAL_ENABLE),.MIDI_CHANNEL(MIDI_CHANNEL)) input_hub(
        .clk(clk),.rst_n(rst_n),.matrix_rows(matrix_rows),.matrix_cols(matrix_cols),
        .adc_scl(adc_scl),.adc_sda(adc_sda),.uart_rx(uart_rx),.uart_tx(uart_tx),
        .synth_overrun(overrun),.suppress_controls(test_owned),
        .note_on(note_on),.note_off(note_off),.note(note),
        .velocity(velocity),.timbre(timbre),.key_state(key_state),
        .selected_timbre(selected_timbre),.keypad_ghost(keypad_ghost),
        .slider_volume(slider_volume),.slider_pitch(slider_pitch),
        .hit0(hit0),.hit1(hit1),.velocity0(velocity0),.velocity1(velocity1),
        .digital_zero_test(digital_zero_test),.adc_fault(adc_fault),.adc_stale(adc_stale),
        .monitor_ready(input_ready),.monitor_remote(input_remote),.monitor_adc(monitor_adc),
        .touch_cs_n(touch_cs_n),.touch_sclk(touch_sclk),.touch_mosi(touch_mosi),.touch_miso(touch_miso),
        .midi_rx(midi_rx),.optical_beams(optical_beams),.sample_tick(monitor_tick),
        .allow_performance(normal_input_ready),.note_source(note_source),.panic_audio(panic_audio),
        .performance_keys(monitor_performance_keys),.external_note(monitor_external_note),
        .external_note_valid(monitor_external_note_valid),
        .pressure_brightness(monitor_expression0),.pressure_vibrato(monitor_expression1),
        .pressure_calibrated(monitor_pressure_calibrated),
        .ui_panic(ui_panic),.ui_strum_mode(ui_strum_mode),
        .ui_timbre_set_valid(ui_timbre_set_valid),.ui_timbre_set_value(ui_timbre_set_value),
        .ui_filter_enable(ui_filter_enable),.ui_zero_mode(ui_zero_mode),
        .control_page(control_page),.ui_fx_cycle(ui_fx_cycle),.filter_enable(input_filter_enable),
        .hat_closed_hit(hat_closed_hit),.hat_open_hit(hat_open_hit),
        .hat_closed_velocity(hat_closed_velocity),.hat_open_velocity(hat_open_velocity),
        .mix_balance(mix_balance),.brightness_base(brightness_base),
        .attack_ctrl(attack_ctrl),.decay_ctrl(decay_ctrl),.sustain_ctrl(sustain_ctrl),.release_ctrl(release_ctrl),
        .fx_mode(monitor_fx_mode),.fx_amount(fx_amount),.fx_time(fx_time),
        .fx_feedback(fx_feedback),.fx_mod(fx_mod),.knob_values(monitor_knob_values),
        .touch_calibrating(touch_calibrating),.touch_diagnostic_pulse(touch_diagnostic_pulse),
        .phone_set_valid(phone_set_valid),.phone_param(phone_param),.phone_value(phone_value),
        .phone_query_param(phone_query_param),.phone_query_value(phone_query_value),
        .monitor_external_diagnostic(monitor_external_diagnostic),
        .monitor_piano_keys32(monitor_piano_keys32),.monitor_piano_outside(monitor_piano_outside));
    wire [8:0] brightness_sum={1'b0,brightness_base}+{1'b0,monitor_expression0};
    wire [7:0] effective_brightness=DISPLAY_TOUCH_ONLY?
        (brightness_sum[8]?8'd255:brightness_sum[7:0]):monitor_expression0;
    instrument_audio #(.LOWPASS_ENABLE(LOWPASS_ENABLE),.NUM_VOICES(32),
        .TRANSITION_INPUT_ENABLE(1),.REDUCED_TIMBRES(1),
        .SOURCE_TAG_ENABLE(MIDI_ENABLE || OPTICAL_ENABLE),.PHASE_RAM(PHASE_RAM),
        .LIVE_ADSR_ENABLE(LIVE_ADSR_ENABLE),.EFFECTS_ENABLE(EFFECTS_ENABLE),
        .CONTROL_BANK_ENABLE(DISPLAY_TOUCH_ONLY),
        .PRESSURE_EXPRESSION_ENABLE(PRESSURE_EXPRESSION_ENABLE)) audio(
        .clk(clk),.rst_n(rst_n),.note_on(note_on),.note_off(note_off),.note(note),
        .velocity(velocity),.timbre(timbre),.slider_volume(slider_volume),.slider_pitch(slider_pitch),
        .hit0(hit0),.hit1(hit1),.velocity0(velocity0),.velocity1(velocity1),
        .digital_zero_test(digital_zero_test || effective_test_mute),.filter_enable(filter_enable),
        .test_owned(test_owned),.test_mode(test_mode),.test_clear(test_clear || panic_audio),
        .normal_input_ready(normal_input_ready),
        .test_gate_mask(test_gate),.test_master_gain(test_gain),
        .hp_bck(hp_bck),.hp_ws(hp_ws),.hp_din(hp_din),.overrun(overrun),
        .monitor_tick(monitor_tick),.monitor_pcm(monitor_pcm),
        .monitor_pitch(monitor_pitch),.monitor_busy(monitor_busy),.monitor_test_busy(monitor_test_busy),
        .event_source(note_source),.pressure_brightness(effective_brightness),
        .pressure_brightness_ready(DISPLAY_TOUCH_ONLY?1'b1:monitor_pressure_calibrated[0]),
        .attack_ctrl(attack_ctrl),.decay_ctrl(decay_ctrl),.sustain_ctrl(sustain_ctrl),.release_ctrl(release_ctrl),
        .damping(DISPLAY_TOUCH_ONLY?monitor_expression1:8'd0),.mix_balance(mix_balance),
        .hat_closed_hit(hat_closed_hit),.hat_open_hit(hat_open_hit),
        .hat_closed_velocity(hat_closed_velocity),.hat_open_velocity(hat_open_velocity),
        .fx_mode(monitor_fx_mode),.fx_amount(fx_amount),.fx_time(fx_time),
        .fx_feedback(fx_feedback),.fx_mod(fx_mod));
    wire [3:0] normal_led_n;
    instrument_status status(.clk(clk),.rst_n(rst_n),
        .key_state(test_owned?16'd0:key_state),.keypad_ghost(keypad_ghost),
        .selected_timbre(selected_timbre),.note_on(note_on),.hit0(hit0),.hit1(hit1),
        .digital_zero_test(digital_zero_test),.adc_fault(adc_fault),.adc_stale(adc_stale),
        .filter_enable(status_filter_enable),.timbre_led_n(normal_led_n));
    // 测试时两组LED交替提示；合成超时优先全灯闪。普通模式沿用原状态灯。
    reg [24:0] test_led_counter;
    always @(posedge clk or negedge rst_n)
        if(!rst_n)test_led_counter<=0;else test_led_counter<=test_led_counter+1'b1;
    assign timbre_led_n=test_owned?
        (overrun?{4{test_led_counter[22]}}:(test_led_counter[22]?4'b1010:4'b0101)):normal_led_n;
    // 当前板载耳机模拟级 PA_EN 固定为1；不是外部功放的使能请求。
    assign pa_en=1'b1;
    // 复用CST已预留的B14/A15/B13；端口名amp_*仅为保持原引脚和顶层接口。
    // 与板载PT8211并行读取最终PCM，包含静音/音量/FSR/32频测试的同一结果。
    // 使用整机rst_n，不使用panic/test_clear局部复位，保持外部DAC时钟连续。
    pcm5102a_i2s external_dac(.clk(clk),.rst_n(rst_n),.sample(monitor_pcm),
        .bck(amp_bck),.lrck(amp_lrc),.din(amp_din));
// 只读状态出口；原来的音频、串口和实体接线保持不变。
    assign monitor_rst_n=rst_n;
    assign monitor_keys=key_state;
    assign monitor_timbre=selected_timbre;
    assign monitor_volume=slider_volume;
    assign monitor_flags={overrun,keypad_ghost,input_ready,adc_stale,
                          adc_fault,filter_enable,input_remote,digital_zero_test};
    assign monitor_test_owned=test_owned;
    assign monitor_test_mode=test_mode;
    assign monitor_test_gate=test_gate;
    assign monitor_test_requested=test_requested;
    assign monitor_test_sweep=test_sweep;
    assign monitor_test_index=test_index;
endmodule
