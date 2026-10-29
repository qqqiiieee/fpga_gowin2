// 系统入口与连接契约：27MHz H11；音频层产生配置后复位和93750Hz采样使能。
// 音频实时路径不依赖HDMI锁定、菜单页或渲染耗时；监视支路只读PCM与状态。
// 层次：u_audio（输入/声音/LED）→u_telemetry（统计）→u_menu/u_guide（交互）→u_display。
// UI_HOLD_SAMPLES默认75000=0.8s；TEST_*按采样数，其他参数见对应子模块。
// 端口对应src/multi_tone.cst；无外部复位端口。hp_*接板载PT8211，amp_*仅固定0。
// 数字统计不包含耳机模拟噪声，频率显示取代表音符，不能代替32路FFT验证。
// keys低12位发音，高4位控制；test_owned期间暂停菜单/教学，涵盖所有渐变交接。
// ui_page 0演奏 1曲库 2帮助 3诊断；ui_song 0小星星 1欢乐颂 2两只老虎。
// ADC低到高A0/A1压力、A2音量、A3弯音；显示压力是压缩ADC码，不是kg。
// 跟弹step内部从0计，显示加1；仅三个练习序列，不存在自动伴奏。
// flags语义继承audio_top；ghost不代表确定的真实按键，组合键先按后松确认。

// V009 refactored audio/remote path plus passive telemetry and onboard HDMI UI.
module top #(parameter LOWPASS_ENABLE=1,parameter VIRTUAL_ADC_CYCLES=63390,parameter TOUCH_ENABLE=1,
 parameter MIDI_ENABLE=1,parameter OPTICAL_ENABLE=1,parameter MIDI_CHANNEL=0,parameter PHASE_RAM=1,
 parameter PRESSURE_EXPRESSION_ENABLE=1,
 parameter TEST_HOLD_SAMPLES=187500,parameter TEST_MAX_SAMPLES=5625000,
 parameter TEST_SWEEP_HALF_SAMPLES=46875,parameter TEST_RAMP_DIV=8,parameter UI_HOLD_SAMPLES=75000)(
 input clk,output [3:0] matrix_rows,input [3:0] matrix_cols,
 output hp_bck,hp_ws,hp_din,pa_en,output amp_bck,amp_lrc,amp_din,
 inout adc_scl,adc_sda,output [3:0] timbre_led_n,
 input uart_rx,output uart_tx,
 output tmds_clk_p,tmds_clk_n,output [2:0] tmds_data_p,tmds_data_n,
 output touch_cs_n,touch_sclk,touch_mosi,input touch_miso,
 input midi_rx,input [1:0] optical_beams);
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
 wire [7:0] expression0,expression1;
 wire [1:0] pressure_calibrated;
 instrument_audio_top #(.LOWPASS_ENABLE(LOWPASS_ENABLE),.VIRTUAL_ADC_CYCLES(VIRTUAL_ADC_CYCLES),.TOUCH_ENABLE(TOUCH_ENABLE),
  .MIDI_ENABLE(MIDI_ENABLE),.OPTICAL_ENABLE(OPTICAL_ENABLE),.MIDI_CHANNEL(MIDI_CHANNEL),.PHASE_RAM(PHASE_RAM),
  .PRESSURE_EXPRESSION_ENABLE(PRESSURE_EXPRESSION_ENABLE),
  .TEST_HOLD_SAMPLES(TEST_HOLD_SAMPLES),.TEST_MAX_SAMPLES(TEST_MAX_SAMPLES),
  .TEST_SWEEP_HALF_SAMPLES(TEST_SWEEP_HALF_SAMPLES),.TEST_RAMP_DIV(TEST_RAMP_DIV)) u_audio(
  .clk(clk),.matrix_rows(matrix_rows),.matrix_cols(matrix_cols),
  .hp_bck(hp_bck),.hp_ws(hp_ws),.hp_din(hp_din),.pa_en(pa_en),
  .amp_bck(amp_bck),.amp_lrc(amp_lrc),.amp_din(amp_din),
  .adc_scl(adc_scl),.adc_sda(adc_sda),.timbre_led_n(timbre_led_n),
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
  .monitor_pressure_calibrated(pressure_calibrated));
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
 instrument_ui_control #(.HOLD_SAMPLES(UI_HOLD_SAMPLES)) u_menu(
  .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),.keys(keys),.ghost(flags[6]),
  .test_owned(test_owned),.remote_active(flags[1]),.page(ui_page),.cursor(ui_cursor),.song_id(ui_song),
  .song_start(ui_start),.song_toggle(ui_toggle),.song_restart(ui_restart));
 wire guide_active,guide_done;
 wire [11:0] cue_mask,next_mask,wrong_mask;
 wire [5:0] guide_step,guide_total;
 wire [7:0] beat_progress;
 wire [1:0] target_beats;
 // 单键菜单操作/验证快捷键在松开前也暂停跟弹，防止把菜单按键当成错误音符。
 // 原跟弹/重开双键仍交由song_guide识别，不被这个暂停条件屏蔽。
 wire menu_key_pause=(|keys[15:14]) && keys!=16'h9000 && keys!=16'h3000;
 song_guide #(.EXTERNAL_UI(1)) u_guide(.clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),.pause(test_owned || ui_page!=0 || menu_key_pause),
  .song_id(ui_song),.ui_start(ui_start),.ui_toggle(ui_toggle),.ui_restart(ui_restart),
  .keys({keys[15:12],performance_keys}),.ghost(flags[6]),.active(guide_active),.done(guide_done),
  .cue_mask(cue_mask),.next_mask(next_mask),.wrong_mask(wrong_mask),
  .step_index(guide_step),.total_steps(guide_total),.beat_progress(beat_progress),
  .target_beats(target_beats));
 wire pll_locked,frame_tick;
 hdmi_live_display #(.UI_ENABLE(1)) u_display(.clk27(clk),.rst_n(rst_n),.sample_tick(sample_tick),
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
  .ui_page(ui_page),.ui_cursor(ui_cursor),.ui_song(ui_song),.ui_controls(keys[15:12]),
  .tmds_clk_p(tmds_clk_p),.tmds_clk_n(tmds_clk_n),
  .tmds_data_p(tmds_data_p),.tmds_data_n(tmds_data_n),
  .pll_locked(pll_locked),.frame_tick(frame_tick));
endmodule
