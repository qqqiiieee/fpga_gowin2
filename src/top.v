// 系统入口与连接契约：27MHz H11；音频层产生配置后复位和93750Hz采样使能。
// 音频实时路径不依赖HDMI锁定、菜单页或渲染耗时；监视支路只读PCM与状态。
// 层次：u_audio（输入/声音/LED）→u_telemetry（统计）→u_menu/u_guide（交互）→u_display。
// BUTTON_DEBOUNCE_CYCLES默认540000=20ms；TEST_*按采样数，其他参数见对应子模块。
// 端口对应src/multi_tone.cst；无外部复位端口。hp_*接板载PT8211，amp_*接PCM5102A标准I2S。
// 数字统计不包含耳机模拟噪声，频率显示取代表音符，不能代替32路FFT验证。
// V028：四路共地按键只做菜单，演奏来自MIDI/双光束；旧模拟触摸默认禁用。
// 手机3.3V UART: M14=FPGA RX <- ESP32 TX，M15=FPGA TX -> ESP32 RX。
// 四旋钮固定FX；Pad只打击乐。FTDI调试口与手机串口物理分开，互不抢占。
// ui_page 0演奏 1曲库 2帮助 3诊断；ui_song 0小星星 1欢乐颂 2两只老虎。
// ADC低到高A0明亮度/A1拨弦阻尼、A2主音量；A3本版停用接GND；显示压力是压缩ADC码，不是kg。
// 跟弹step内部从0计，显示加1；仅三个练习序列，不存在自动伴奏。
// flags语义继承audio_top；四键单独同步/消抖，按住不连发，多键取消，松开确认。

// V009 refactored audio/remote path plus passive telemetry and onboard HDMI UI.
module top #(parameter LOWPASS_ENABLE=1,parameter VIRTUAL_ADC_CYCLES=63390,parameter TOUCH_ENABLE=0,
 parameter MIDI_ENABLE=1,parameter OPTICAL_ENABLE=1,parameter MIDI_CHANNEL=0,parameter PHASE_RAM=1,
 parameter PRESSURE_EXPRESSION_ENABLE=1,
 parameter LIVE_ADSR_ENABLE=1,parameter EFFECTS_ENABLE=1,
 parameter TEST_HOLD_SAMPLES=187500,parameter TEST_MAX_SAMPLES=5625000,
 parameter TEST_SWEEP_HALF_SAMPLES=46875,parameter TEST_RAMP_DIV=8,parameter BUTTON_DEBOUNCE_CYCLES=540000,
 parameter PIANO_ROLL_ENABLE=1,parameter GUIDE_BEAT_SAMPLES=46875)(
 input clk,input [3:0] ui_buttons_n,
 output hp_bck,hp_ws,hp_din,pa_en,output amp_bck,amp_lrc,amp_din,
 inout adc_scl,adc_sda,output [3:0] timbre_led_n,
 input uart_rx,output uart_tx,
 output tmds_clk_p,tmds_clk_n,output [2:0] tmds_data_p,tmds_data_n,
 output touch_cs_n,touch_sclk,touch_mosi,input touch_miso,
 input midi_rx,input [1:0] optical_beams,input phone_uart_rx,output phone_uart_tx);
 wire rst_n,sample_tick;
 wire [15:0] pcm,keys;
 wire [3:0] timbre;
 wire [7:0] volume,flags;
 wire signed [8:0] pitch;
 wire [31:0] busy;
 wire [63:0] adc_values;
 wire test_owned,test_mode,test_sweep;
 wire [31:0] test_gate,test_busy;
 wire [5:0] test_requested;
 wire [4:0] test_index;
 wire [11:0] performance_keys;
 wire [6:0] external_note;
 wire external_note_valid;
 // 独立只读显示支路：物理MIDI48..79，不使用旧12位自然音级掩码冒充黑键。
 // 延音踏板尾音、Pad和触摸菜单不点亮这些键；发声仍完整接受MIDI0..127。
 wire [31:0] piano_keys;
 wire piano_outside;
 wire [7:0] expression0,expression1;
 wire [1:0] pressure_calibrated;
 wire [3:0] audio_led_n;
 wire [15:0] ui_test_keys;
 wire ui_panic,ui_timbre_set_valid,ui_fx_cycle;
 reg ui_strum_mode,ui_filter_enable,ui_zero_mode;
 wire [3:0] ui_timbre_set_value;
 wire [1:0] control_page,fx_mode;
 wire [31:0] knob_values;
 wire phone_set,phone_panic;
 wire [7:0] phone_param,phone_value,phone_bank_value;
 wire [13:0] external_diagnostic;
 // 回读状态来自输入诊断与现有UI状态，不用网页请求值冒充生效值。
 wire [7:0] phone_status_exact={1'b0,flags[0],external_diagnostic[4],ui_strum_mode,
     external_diagnostic[5],flags[6],flags[3],external_diagnostic[0]};
 reg [7:0] phone_read_value;
 always @* begin
     phone_read_value=phone_bank_value;
     case(phone_param)
       1:phone_read_value={4'd0,timbre};
       2:phone_read_value={7'd0,ui_strum_mode};
       12:phone_read_value={6'd0,ui_page};
       13:phone_read_value={7'd0,ui_filter_enable};
       14:phone_read_value={7'd0,flags[0]};
       15:phone_read_value=phone_status_exact;
       default:;
     endcase
 end
 phone_control_link u_phone(.clk(clk),.rst_n(rst_n),.rx(phone_uart_rx),.tx(phone_uart_tx),
     .set_valid(phone_set),.panic(phone_panic),.param(phone_param),.value(phone_value),
     .read_value(phone_read_value),.status_flags(phone_status_exact),
     .current_timbre({4'd0,timbre}),.current_fx({6'd0,fx_mode}),.current_volume(volume));
 assign ui_panic=phone_panic;
 assign ui_timbre_set_valid=phone_set && phone_param==1;
 assign ui_timbre_set_value={3'd0,phone_value[0]};
 // Phone-only persistent UI parameters. Do not instantiate the old touch menu:
 // neither physical/virtual touch keys nor four-button chords enter test mode.
 // Readback above uses these actual registers (mute uses effective flags[0]).
 assign ui_test_keys=16'd0;
 assign control_page=2'd2;
 assign ui_fx_cycle=1'b0;
 always @(posedge clk or negedge rst_n)
   if(!rst_n)begin ui_strum_mode<=0;ui_filter_enable<=1;ui_zero_mode<=0;end
   else if(phone_set)case(phone_param)
     2:ui_strum_mode<=phone_value[0];
     13:ui_filter_enable<=phone_value[0];
     14:ui_zero_mode<=phone_value[0];
     default:;
   endcase
 instrument_audio_top #(.LOWPASS_ENABLE(LOWPASS_ENABLE),.VIRTUAL_ADC_CYCLES(VIRTUAL_ADC_CYCLES),.TOUCH_ENABLE(TOUCH_ENABLE),
  .MIDI_ENABLE(MIDI_ENABLE),.OPTICAL_ENABLE(OPTICAL_ENABLE),.MIDI_CHANNEL(MIDI_CHANNEL),.PHASE_RAM(PHASE_RAM),
  .PRESSURE_EXPRESSION_ENABLE(PRESSURE_EXPRESSION_ENABLE),
  .DISPLAY_TOUCH_ONLY(1),.LIVE_ADSR_ENABLE(LIVE_ADSR_ENABLE),.EFFECTS_ENABLE(EFFECTS_ENABLE),
  .TEST_HOLD_SAMPLES(TEST_HOLD_SAMPLES),.TEST_MAX_SAMPLES(TEST_MAX_SAMPLES),
  .TEST_SWEEP_HALF_SAMPLES(TEST_SWEEP_HALF_SAMPLES),.TEST_RAMP_DIV(TEST_RAMP_DIV)) u_audio(
  .clk(clk),.matrix_rows(),.matrix_cols(4'hf),
  .hp_bck(hp_bck),.hp_ws(hp_ws),.hp_din(hp_din),.pa_en(pa_en),
  .amp_bck(amp_bck),.amp_lrc(amp_lrc),.amp_din(amp_din),
  .adc_scl(adc_scl),.adc_sda(adc_sda),.timbre_led_n(audio_led_n),
  .uart_rx(uart_rx),.uart_tx(uart_tx),
  .monitor_rst_n(rst_n),.monitor_tick(sample_tick),.monitor_pcm(pcm),
  .monitor_keys(keys),.monitor_timbre(timbre),.monitor_volume(volume),
  .monitor_pitch(pitch),.monitor_busy(busy),.monitor_flags(flags),.monitor_adc(adc_values),
  .monitor_test_owned(test_owned),.monitor_test_mode(test_mode),
  .monitor_test_gate(test_gate),.monitor_test_busy(test_busy),
  .monitor_test_requested(test_requested),.monitor_test_sweep(test_sweep),.monitor_test_index(test_index),
  .touch_cs_n(touch_cs_n),.touch_sclk(touch_sclk),.touch_mosi(touch_mosi),.touch_miso(touch_miso),
  .midi_rx(midi_rx),.optical_beams(optical_beams),.monitor_performance_keys(performance_keys),
  .monitor_external_note(external_note),.monitor_external_note_valid(external_note_valid),
  .monitor_expression0(expression0),.monitor_expression1(expression1),
  .monitor_pressure_calibrated(pressure_calibrated),
  .ui_test_keys(ui_test_keys),.ui_panic(ui_panic),.ui_strum_mode(ui_strum_mode),
  .ui_timbre_set_valid(ui_timbre_set_valid),.ui_timbre_set_value(ui_timbre_set_value),
  .ui_filter_enable(ui_filter_enable),.ui_zero_mode(ui_zero_mode),
  .control_page(control_page),.ui_fx_cycle(ui_fx_cycle),
  .monitor_fx_mode(fx_mode),.monitor_knob_values(knob_values),
  .phone_set_valid(phone_set),.phone_param(phone_param),.phone_value(phone_value),
  .phone_query_param(phone_param),.phone_query_value(phone_bank_value),
  .monitor_external_diagnostic(external_diagnostic),
  .monitor_piano_keys32(piano_keys),.monitor_piano_outside(piano_outside));
 wire [15:0] peak,rms,hz,freq_bcd;
 wire signed [7:0] level_dbfs;
 wire [7:0] peak_percent,volume_percent;
 wire [5:0] voices;
 wire [6:0] note;
 wire note_valid,clip;
 instrument_telemetry #(.EXTERNAL_NOTE_ENABLE(MIDI_ENABLE || OPTICAL_ENABLE)) u_telemetry(.clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),
  .pcm(pcm),.keys(performance_keys),.volume(volume),.pitch(pitch),.busy(test_owned?test_busy:busy),
  .peak(peak),.rms(rms),.level_dbfs(level_dbfs),.peak_percent(peak_percent),
  .volume_percent(volume_percent),.voices(voices),.primary_note(note),
  .note_valid(note_valid),.frequency_hz(hz),.frequency_bcd(freq_bcd),.clip(clip),
  .external_note(external_note),.external_note_valid(external_note_valid && !test_owned));
 wire [1:0] ui_page,ui_cursor,ui_song;
 wire ui_start,ui_toggle,ui_restart;
 wire menu_key_pause;
 wire [3:0] buttons_down;
 four_button_display_control #(.DEBOUNCE_CYCLES(BUTTON_DEBOUNCE_CYCLES)) u_menu(
  .clk(clk),.rst_n(rst_n),.keys_n(ui_buttons_n),.guide_done(guide_done),
  .test_owned(test_owned),.page(ui_page),.cursor(ui_cursor),.song_id(ui_song),
  .song_start(ui_start),.song_toggle(ui_toggle),.song_restart(ui_restart),.key_pause(menu_key_pause),
  .buttons_down(buttons_down),
  .phone_set_valid(phone_set),.phone_param(phone_param),.phone_value(phone_value));
 wire guide_active,guide_done;
 wire [11:0] cue_mask,next_mask,wrong_mask;
 wire [5:0] guide_step,guide_total;
 wire [7:0] beat_progress;
 wire [1:0] target_beats;
 // 四键首次开始/选曲后等待开始；菜单按住、非演奏页和测试所有权冻结谱面。
 // 四键事件不接入音符路径，手机切页不隐式开始、选曲或重播。
 wire beat_pulse;
 wire [11:0] roll_tick;
 wire [1:0] roll_song;
 generate if(PIANO_ROLL_ENABLE)begin:falling_guide
 // 新版是纯视觉时间轴：120BPM自动走拍，先两拍预备，不等待按键，也不驱动声音。
 // 菜单/非演奏页/32路验证冻结谱面；现有演奏、尾音及手机通信保持原路径。
 piano_roll_guide #(.BEAT_SAMPLES(GUIDE_BEAT_SAMPLES)) u_roll(
  .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),
  .pause(test_owned || ui_page!=0 || menu_key_pause),
  .song_id(ui_song),.ui_start(ui_start),.ui_toggle(ui_toggle),.ui_restart(ui_restart),
  .roll_tick(roll_tick),.roll_song(roll_song),.active(guide_active),.done(guide_done),
  .step_index(guide_step),.total_steps(guide_total),.beat_progress(beat_progress),
  .target_beats(target_beats),.beat_pulse(beat_pulse),.cue_mask(cue_mask),.next_mask(next_mask),
  .expected_note(),.expected_valid(),.count_in(),.total_beats());
 // 诊断摘要继续保留下个音；下落谱面从共享曲谱ROM按未来时间读取，长音不被切开。
 assign wrong_mask=(guide_active && target_beats!=0) ? (performance_keys & ~cue_mask) : 12'd0;
 end else begin:legacy_guide
 assign roll_tick=0;assign roll_song=0;
 song_guide #(.EXTERNAL_UI(1),.RHYTHM_ENABLE(1)) u_guide(.clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),.pause(test_owned || ui_page!=0 || menu_key_pause),
  .song_id(ui_song),.ui_start(ui_start),.ui_toggle(ui_toggle),.ui_restart(ui_restart),
  .keys({4'd0,performance_keys}),.ghost(1'b0),.active(guide_active),.done(guide_done),
  .cue_mask(cue_mask),.next_mask(next_mask),.wrong_mask(wrong_mask),
  .step_index(guide_step),.total_steps(guide_total),.beat_progress(beat_progress),
  .target_beats(target_beats),.beat_pulse(beat_pulse));
 end endgenerate
 wire pll_locked,frame_tick;
 // 沿用现有四颗LED，LED5辅助节拍、LED4辅助错键；测试和overrun状态优先。
 // 这是HDL生成的辅助指引，不宣称等价逐琴键灯带。
 reg [12:0] beat_led_hold;
 always @(posedge clk or negedge rst_n)
   if(!rst_n)beat_led_hold<=0;
   else if(beat_pulse)beat_led_hold<=13'd4687;
   else if(sample_tick && beat_led_hold!=0)beat_led_hold<=beat_led_hold-1'b1;
 assign timbre_led_n=(test_owned || flags[7])?audio_led_n:
   {(guide_active && ui_page==0)?(beat_led_hold==0):audio_led_n[3],
    (|wrong_mask)?1'b0:audio_led_n[2],audio_led_n[1:0]};
 hdmi_live_display #(.UI_ENABLE(1),.COMPACT_UI(1),.PIANO_ROLL_ENABLE(PIANO_ROLL_ENABLE)) u_display(.clk27(clk),.rst_n(rst_n),.sample_tick(sample_tick),
  .pcm(pcm),.peak(peak),.keys(performance_keys),.timbre(timbre),.note(note),.note_valid(note_valid),
  .frequency_bcd(freq_bcd),.volume_percent(volume_percent),.level_dbfs(level_dbfs),
  .peak_percent(peak_percent),.pitch(pitch),.voices(voices),
  // 表情版显示实际0..255平滑控制量，而非旧鼓的压缩原始ADC码。
  .pressure0(PRESSURE_EXPRESSION_ENABLE?expression0:(adc_values[15]?8'd0:adc_values[14:7])),
  .pressure1(PRESSURE_EXPRESSION_ENABLE?expression1:(adc_values[31]?8'd0:adc_values[30:23])),.flags(flags),
  .guide_active(guide_active),.guide_done(guide_done),.cue_mask(cue_mask),
  .next_mask(next_mask),.wrong_mask(wrong_mask),.guide_step(guide_step+6'd1),
  .guide_total(guide_total),.beat_progress(beat_progress),.target_beats(target_beats),.clip(clip),
  .test_active(test_owned),.test_requested(test_requested),.test_busy(test_busy),.test_gate(test_gate),
  .test_sweep(test_sweep),.test_index(test_index),.test_overrun(flags[7]),
  .ui_page(ui_page),.ui_cursor(ui_cursor),.ui_song(ui_song),.ui_controls(buttons_down),
  .control_page(control_page),.fx_mode(fx_mode),.strum_mode(ui_strum_mode),.knob_values(knob_values),
  .piano_keys(piano_keys),.piano_outside(piano_outside),.roll_tick(roll_tick),.roll_song(roll_song),
  .roll_active(guide_active),.roll_done(guide_done),
  .tmds_clk_p(tmds_clk_p),.tmds_clk_n(tmds_clk_n),
  .tmds_data_p(tmds_data_p),.tmds_data_n(tmds_data_n),
  .pll_locked(pll_locked),.frame_tick(frame_tick));
endmodule
