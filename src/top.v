// 系统入口与连接契约：27MHz H11；音频层产生配置后复位和93750Hz采样使能。
// 音频实时路径不依赖HDMI锁定、菜单页或渲染耗时；监视支路只读PCM与状态。
// 层次：u_audio（输入/声音/LED）→u_telemetry（统计）→u_menu/u_guide（交互）→u_display。
// BUTTON_DEBOUNCE_CYCLES默认540000=20ms；TEST_*按采样数，其他参数见对应子模块。
// 端口对应src/multi_tone.cst；无外部复位端口。hp_*接板载PT8211，amp_*接PCM5102A标准I2S。
// 数字统计不包含耳机模拟噪声，频率显示取代表音符，不能代替32路FFT验证。
// V028：四路共地按键只做菜单，演奏来自MIDI/双光束；旧模拟触摸默认禁用。
// 手机3.3V UART: PMOD3 L9=FPGA RX <- ESP32 D17，N8=FPGA TX -> ESP32 D16。
// 四旋钮固定FX；Pad只打击乐。FTDI调试口与手机串口物理分开，互不抢占。
// ui_page 0演奏 1曲库 2可视化(FFT/李萨如) 3诊断；V045曲库0小星星1灯阶2溪桥3自定义。
// V035：面板长按3进入32路验证；诊断页集中显示力度/弯音/CC1与双FSR。
// ADC仅采A0明亮度/A1拨弦阻尼；A2/A3滑杆停用接GND；原始码和表情值均不是kg。
// 跟弹step内部从0计，显示加1；自动模式单音示范，非多轨伴奏。
// flags语义继承audio_top；四键单独同步/消抖，按住不连发，多键取消，松开确认。

// V009 refactored audio/remote path plus passive telemetry and onboard HDMI UI.
module top #(parameter LOWPASS_ENABLE=1,parameter VIRTUAL_ADC_CYCLES=63390,parameter TOUCH_ENABLE=0,
 parameter MIDI_ENABLE=1,parameter OPTICAL_ENABLE=1,parameter MIDI_CHANNEL=0,parameter PHASE_RAM=1,
 parameter PRESSURE_EXPRESSION_ENABLE=1,
 parameter LIVE_ADSR_ENABLE=1,parameter EFFECTS_ENABLE=1,
 parameter TEST_HOLD_SAMPLES=187500,parameter TEST_MAX_SAMPLES=5625000,
 parameter TEST_SWEEP_HALF_SAMPLES=46875,parameter TEST_RAMP_DIV=8,parameter BUTTON_DEBOUNCE_CYCLES=540000,
 parameter BUTTON_LONG_PRESS_CYCLES=21600000,
 parameter PIANO_ROLL_ENABLE=1,parameter GUIDE_BEAT_SAMPLES=46875,
 parameter CHORD_SCORE_ENABLE=1,parameter PHONE_BAUD=1000000,parameter SONG_LIBRARY_ENABLE=1,parameter GUIDE_MODES_ENABLE=1)(
 input clk,input [3:0] ui_buttons_n,
 output hp_bck,hp_ws,hp_din,pa_en,output amp_bck,amp_lrc,amp_din,
 inout adc_scl,adc_sda,output [3:0] timbre_led_n,
 input uart_rx,output uart_tx,
 output tmds_clk_p,tmds_clk_n,output [2:0] tmds_data_p,tmds_data_n,
 input midi_rx,input [1:0] optical_beams,input phone_uart_rx,output phone_uart_tx);
 // V040：MCP3208已撤除。保留内部兼容线供历史层次测试，不再分配物理IO。
 wire touch_cs_n,touch_sclk,touch_mosi;
 wire touch_miso=1'b1;
 wire rst_n,sample_tick;
 wire [15:0] pcm,keys;
 // V036可视化只读支路：最终PCM供FFT，独立声部0/1（混音和FX前）供XY。
 wire signed [15:0] visual_voice0,visual_voice1;
 wire [3:0] timbre;
 wire [7:0] volume,flags;
 wire signed [8:0] pitch;
 wire [31:0] busy;
 wire [5:0] voices;
 wire [63:0] adc_values;
 wire test_owned,test_mode,test_sweep;
 wire [31:0] test_gate,test_busy;
 wire [5:0] test_requested;
 wire [4:0] test_index;
 wire [11:0] performance_keys;
 wire [6:0] external_note;
 wire external_note_valid;
 // 独立只读显示支路：物理MIDI默认41..72（F2..C5，piano_layout.vh），保留全部黑白键。
 // 延音踏板尾音、Pad和触摸菜单不点亮这些键；发声仍完整接受MIDI0..127。
 wire [31:0] piano_keys;
 wire piano_outside;
 wire [7:0] expression0,expression1;
 wire [1:0] pressure_calibrated;
 wire [3:0] audio_led_n;
 wire [15:0] ui_test_keys;
 wire ui_panic,ui_timbre_set_valid,ui_fx_cycle;
 // 一个模式寄存器统一面板、手机回读、HDMI和输入仲裁：0 KEY/1 STRUM/2 HYBRID。
 reg [1:0] ui_strum_mode;
 reg ui_filter_enable,ui_zero_mode;
 wire panel_timbre_cycle,panel_mode_cycle,panel_guide_mode_cycle;
 wire guide_active,guide_done;
 reg [1:0] guide_mode;
 wire phone_guide_mode_valid;wire [1:0] phone_guide_mode_value,phone_guide_song;
 wire note_receipt;wire [6:0] raw_receipt_note;
 wire practice_hold,guide_score_ready,guide_expected_valid;
 wire [6:0] guide_expected_note;
 wire [14:0] guide_expected_offsets,guide_demo_offsets;
 wire guide_demo_valid,guide_demo_retrigger;wire [6:0] guide_demo_note;
 wire guide_external_pause=test_owned || ui_page!=0 || menu_key_pause;
 // Single mode owner: phone absolute mode outranks panel's cycle request.
 always @(posedge clk or negedge rst_n)
  if(!rst_n)guide_mode<=0;
  else if(GUIDE_MODES_ENABLE && phone_guide_mode_valid)guide_mode<=phone_guide_mode_value;
  else if(GUIDE_MODES_ENABLE && panel_guide_mode_cycle)guide_mode<=guide_mode==2?2'd0:guide_mode+2'd1;
 wire [23:0] guide_status={ui_song,guide_expected_valid,guide_expected_note,
     guide_step,guide_external_pause,practice_hold,guide_done,guide_active,roll_song,guide_mode};
 wire panel_test_toggle,panel_test_count_cycle,panel_test_sweep_toggle,panel_test_full;
 wire [7:0] midi_velocity;
 wire signed [8:0] midi_bend;
 wire [6:0] midi_modulation;
 // 原32路引擎负责所有权、淡入淡出和超时。面板只提交控制，不碰音频gate。
 // 菜单事件在时钟沿寄存；同时保存事件生成时的所有权，避免退出淡入
 // 恰好结束时把旧“退出”脉冲误判成新“进入”。跨所有权边界的事件丢弃。
 reg panel_test_owned_q;
 always @(posedge clk or negedge rst_n) begin
     if(!rst_n) panel_test_owned_q<=1'b0;
     else panel_test_owned_q<=test_owned;
 end
 wire panel_test_enter=panel_test_toggle && !panel_test_owned_q && !test_owned;
 wire panel_test_exit=panel_test_toggle && panel_test_owned_q && test_owned;
 wire panel_test_count_valid=panel_test_owned_q && test_owned &&
      (panel_test_count_cycle || panel_test_full || (panel_test_sweep_toggle && test_sweep));
 wire [5:0] panel_test_count=(panel_test_full || panel_test_sweep_toggle)?6'd32:
      (test_requested==1?6'd4:test_requested==4?6'd8:
       test_requested==8?6'd16:test_requested==16?6'd32:6'd1);
 wire panel_test_sweep_start=panel_test_owned_q && test_owned && panel_test_sweep_toggle && !test_sweep;
 wire [3:0] ui_timbre_set_value;
 wire [1:0] control_page,fx_mode;
 wire [31:0] knob_values;
 wire phone_set,phone_panic,phone_get;
 wire [7:0] phone_param,phone_value,phone_bank_value;
 wire [13:0] external_diagnostic;
 wire [7:0] phone_sensor_value;
 // V041 extensions use the same three phone wires. File parsing/storage lives
 // on ESP32; score display, mapping and passive final-PCM capture stay in HDL.
 wire ext_valid,ext_done;wire [7:0]ext_op,ext_status;wire[39:0]ext_data;wire[31:0]ext_reply;
 wire score_wr_en;wire[8:0]score_wr_addr;wire[31:0]score_wr_data,custom_score_config;
 wire custom_pixel_bank_ack,phone_guide_command_valid;wire[1:0]phone_guide_command;
 wire mapping_enable,mapping_bank,mapping_commit,mapping_wr_en;
 wire[7:0]mapping_wr_addr;wire[6:0]mapping_wr_data;wire[27:0]mapping_pad_notes,mapping_cc_numbers;
 wire mapping_wr_ready,mapping_commit_ready,mapping_commit_ack;
 wire record_start,record_stop,record_active,record_busy,record_packet_valid,record_packet_ready;
 wire[31:0]record_count,record_crc32;wire[15:0]record_dropped;
 wire[7:0]record_packet_type;wire[47:0]record_packet_payload;
 wire mapping_performance_idle=!test_owned && piano_keys==0 && !piano_outside && !external_diagnostic[6];
 // 同源时钟域内原子锁存快照。GET16触发，GET17..30继续读这份快照。
 // UART控制器已有6周期settle，因此GET16的ACK包含本次新快照首字节。
 phone_telemetry_snapshot phone_sensor_snapshot(.clk(clk),.rst_n(rst_n),
     .capture(phone_get && phone_param==8'd16),.index(phone_param),
     .adc_raw(adc_values[31:0]),.pressure0(expression0),.pressure1(expression1),
     .calibrated(pressure_calibrated),.flags(flags),.external_diagnostic(external_diagnostic),
     .midi_velocity(midi_velocity),.midi_bend(midi_bend),.midi_modulation(midi_modulation),
     .voices(voices),.test_requested(test_requested),.test_owned(test_owned),
     .test_mode(test_mode),.test_sweep(test_sweep),.test_index(test_index),.value(phone_sensor_value));
 // 回读状态来自输入诊断与现有UI状态，不用网页请求值冒充生效值。
 wire [7:0] phone_status_exact={1'b0,flags[0],external_diagnostic[4],(ui_strum_mode!=0),
     external_diagnostic[5],flags[6],flags[3],external_diagnostic[0]};
 reg [7:0] phone_read_value;
 always @* begin
     phone_read_value=phone_bank_value;
     case(phone_param)
       1:phone_read_value={4'd0,timbre};
       2:phone_read_value={6'd0,ui_strum_mode};
       12:phone_read_value={6'd0,ui_page};
       13:phone_read_value={7'd0,ui_filter_enable};
       14:phone_read_value={7'd0,flags[0]};
       15:phone_read_value=phone_status_exact;
       default:if(phone_param>=16 && phone_param<=31)phone_read_value=phone_sensor_value;
     endcase
 end
 phone_extended_link #(.TELEMETRY_ENABLE(1),.BAUD(PHONE_BAUD)) u_phone(.clk(clk),.rst_n(rst_n),.rx(phone_uart_rx),.tx(phone_uart_tx),
     .set_valid(phone_set),.panic(phone_panic),.param(phone_param),.value(phone_value),
     .read_value(phone_read_value),.status_flags(phone_status_exact),
     .current_timbre({4'd0,timbre}),.current_fx({6'd0,fx_mode}),.current_volume(volume),.get_valid(phone_get),
     .ext_valid(ext_valid),.ext_op(ext_op),.ext_data(ext_data),.ext_done(ext_done),.ext_status(ext_status),.ext_reply(ext_reply),
     .audio_valid(record_packet_valid),.audio_type(record_packet_type),.audio_payload(record_packet_payload),.audio_ready(record_packet_ready));
 phone_extension_state #(.CHORD_SCORE_ENABLE(CHORD_SCORE_ENABLE),.GUIDE_MODES_ENABLE(GUIDE_MODES_ENABLE)) extension_state(.clk(clk),.rst_n(rst_n),.request_valid(ext_valid),.op(ext_op),.data(ext_data),
     .done(ext_done),.status(ext_status),.reply(ext_reply),.performance_idle(mapping_performance_idle),
     .pixel_bank_ack(custom_pixel_bank_ack),.test_owned(test_owned),
     .score_wr_en(score_wr_en),.score_wr_addr(score_wr_addr),.score_wr_data(score_wr_data),.score_config(custom_score_config),
     .guide_command_valid(phone_guide_command_valid),.guide_command(phone_guide_command),
     .guide_song(phone_guide_song),.guide_mode_valid(phone_guide_mode_valid),.guide_mode_value(phone_guide_mode_value),.guide_status(guide_status),
     .mapping_enable(mapping_enable),.mapping_bank(mapping_bank),.mapping_commit(mapping_commit),
     .mapping_wr_en(mapping_wr_en),.mapping_wr_addr(mapping_wr_addr),.mapping_wr_data(mapping_wr_data),
     .mapping_pad_notes(mapping_pad_notes),.mapping_cc_numbers(mapping_cc_numbers),
     .mapping_wr_ready(mapping_wr_ready),.mapping_commit_ready(mapping_commit_ready),.mapping_commit_ack(mapping_commit_ack),
     .record_start(record_start),.record_stop(record_stop),.record_active(record_active),.record_busy(record_busy),
     .record_count(record_count),.record_crc32(record_crc32),.record_dropped(record_dropped));
 phone_record_tap recorder(.clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),.pcm(pcm),.start(record_start),.stop(record_stop),
     .active(record_active),.sample_count(record_count),.dropped(record_dropped),.busy(record_busy),.pcm_crc32(record_crc32),
     .packet_valid(record_packet_valid),.packet_type(record_packet_type),.packet_payload(record_packet_payload),.packet_ready(record_packet_ready));
 assign ui_panic=phone_panic;
 // 同周期手机绝对值优先于面板切换；MIDI Program Change在后级保持低优先级。
 assign ui_timbre_set_valid=(phone_set && phone_param==1) || panel_timbre_cycle;
 assign ui_timbre_set_value=(phone_set && phone_param==1)?{3'd0,phone_value[0]}:
                           (timbre==1?4'd0:4'd1);
 // 四键长按仅改参数，不实例化旧电容菜单或伪造演奏音符。
 // 旧矩阵/虚拟触摸键仍不进入测试；V035由四键长按3提交独立验证命令。
 // Readback above uses these actual registers (mute uses effective flags[0]).
 assign ui_test_keys=16'd0;
 assign control_page=2'd2;
 assign ui_fx_cycle=1'b0;
 always @(posedge clk or negedge rst_n)
   if(!rst_n)begin ui_strum_mode<=0;ui_filter_enable<=1;ui_zero_mode<=0;end
   else begin
     if(phone_set && phone_param==2)ui_strum_mode<=phone_value[1:0];
     else if(panel_mode_cycle)ui_strum_mode<=ui_strum_mode==2?2'd0:ui_strum_mode+2'd1;
     if(phone_set && phone_param==13)ui_filter_enable<=phone_value[0];
     if(phone_set && phone_param==14)ui_zero_mode<=phone_value[0];
   end
 instrument_audio_top #(.LOWPASS_ENABLE(LOWPASS_ENABLE),.VIRTUAL_ADC_CYCLES(VIRTUAL_ADC_CYCLES),.TOUCH_ENABLE(TOUCH_ENABLE),
  .MIDI_ENABLE(MIDI_ENABLE),.OPTICAL_ENABLE(OPTICAL_ENABLE),.MIDI_CHANNEL(MIDI_CHANNEL),.PHASE_RAM(PHASE_RAM),
  .PRESSURE_EXPRESSION_ENABLE(PRESSURE_EXPRESSION_ENABLE),
  .DISPLAY_TOUCH_ONLY(1),.LIVE_ADSR_ENABLE(LIVE_ADSR_ENABLE),.EFFECTS_ENABLE(EFFECTS_ENABLE),
  .CHORD_SCORE_ENABLE(CHORD_SCORE_ENABLE),.PANEL_TEST_ENABLE(1),.VISUAL_MONITOR_ENABLE(1),.MAPPING_ENABLE(1),.GUIDE_MODES_ENABLE(GUIDE_MODES_ENABLE),
  .TEST_HOLD_SAMPLES(TEST_HOLD_SAMPLES),.TEST_MAX_SAMPLES(TEST_MAX_SAMPLES),
  .TEST_SWEEP_HALF_SAMPLES(TEST_SWEEP_HALF_SAMPLES),.TEST_RAMP_DIV(TEST_RAMP_DIV)) u_audio(
  .clk(clk),.matrix_rows(),.matrix_cols(4'hf),
  .mapping_enable(mapping_enable),.mapping_bank(mapping_bank),.mapping_commit(mapping_commit),
  .mapping_wr_en(mapping_wr_en),.mapping_wr_addr(mapping_wr_addr),.mapping_wr_data(mapping_wr_data),
  .mapping_pad_notes(mapping_pad_notes),.mapping_cc_numbers(mapping_cc_numbers),
  .mapping_wr_ready(mapping_wr_ready),.mapping_commit_ready(mapping_commit_ready),.mapping_commit_ack(mapping_commit_ack),
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
  .monitor_piano_keys32(piano_keys),.monitor_piano_outside(piano_outside),
  .monitor_midi_velocity(midi_velocity),.monitor_midi_bend(midi_bend),
  .monitor_midi_modulation(midi_modulation),
  .ui_test_enter(panel_test_enter),.ui_test_exit(panel_test_exit),
  .ui_test_count_valid(panel_test_count_valid),.ui_test_count(panel_test_count),
  .ui_test_sweep_start(panel_test_sweep_start),
  .monitor_voice0(visual_voice0),.monitor_voice1(visual_voice1),
  .monitor_note_receipt(note_receipt),.monitor_raw_note(raw_receipt_note),
  .guide_demo_offsets(guide_demo_offsets),.guide_demo_valid(guide_demo_valid),.guide_demo_note(guide_demo_note),.guide_demo_retrigger(guide_demo_retrigger));
 wire [15:0] peak,rms,hz,freq_bcd;
 wire signed [7:0] level_dbfs;
 wire [7:0] peak_percent,volume_percent;
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
 four_button_display_control #(.DEBOUNCE_CYCLES(BUTTON_DEBOUNCE_CYCLES),
  .LONG_PRESS_CYCLES(BUTTON_LONG_PRESS_CYCLES),.CUSTOM_SONG_ENABLE(1),.GUIDE_MODES_ENABLE(GUIDE_MODES_ENABLE)) u_menu(
  .clk(clk),.rst_n(rst_n),.keys_n(ui_buttons_n),.guide_done(guide_done),
  .test_owned(test_owned),.page(ui_page),.cursor(ui_cursor),.song_id(ui_song),
  .custom_song_available(custom_score_config[30]),.phone_song_command_valid(phone_guide_command_valid),.phone_song_command(phone_guide_command),
  .song_start(ui_start),.song_toggle(ui_toggle),.song_restart(ui_restart),.key_pause(menu_key_pause),
  .phone_song_id(phone_guide_song),.phone_guide_mode_valid(phone_guide_mode_valid),.guide_mode_cycle(panel_guide_mode_cycle),.guide_stop(phone_panic),
  .buttons_down(buttons_down),
  .phone_set_valid(phone_set),.phone_param(phone_param),.phone_value(phone_value),
  .timbre_cycle(panel_timbre_cycle),.mode_cycle(panel_mode_cycle),
  .test_toggle(panel_test_toggle),.test_count_cycle(panel_test_count_cycle),
  .test_sweep_toggle(panel_test_sweep_toggle),.test_full(panel_test_full));
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
 // V045共享时间轴：固定BPM/自动示范/逐音练习；两拍预备，模式模块只冻结guide。
 // 菜单/非演奏页/32路验证冻结谱面；现有演奏、尾音及手机通信保持原路径。
 piano_roll_guide #(.BEAT_SAMPLES(GUIDE_BEAT_SAMPLES),.CUSTOM_SCORE_ENABLE(1),.SONG_LIBRARY_ENABLE(SONG_LIBRARY_ENABLE)) u_roll(
  .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),
  .custom_write_clk(clk),.custom_write_en(score_wr_en),.custom_write_addr(score_wr_addr),.custom_write_data(score_wr_data),.custom_config(custom_score_config),
  .pause(guide_external_pause || practice_hold),
  .song_id(ui_song),.ui_start(ui_start),.ui_toggle(ui_toggle),.ui_restart(ui_restart),
  .roll_tick(roll_tick),.roll_song(roll_song),.active(guide_active),.done(guide_done),
  .step_index(guide_step),.total_steps(guide_total),.beat_progress(beat_progress),
  .target_beats(target_beats),.beat_pulse(beat_pulse),.cue_mask(cue_mask),.next_mask(next_mask),
  .expected_note(guide_expected_note),.expected_valid(guide_expected_valid),
  .expected_offsets(guide_expected_offsets),.score_ready(guide_score_ready),.count_in(),.total_beats());
 // 诊断摘要继续保留下个音；下落谱面从共享曲谱ROM按未来时间读取，长音不被切开。
 assign wrong_mask=(guide_active && target_beats!=0) ? (performance_keys & ~cue_mask) : 12'd0;
 end else begin:legacy_guide
 assign roll_tick=0;assign roll_song=0;
 assign guide_expected_offsets=0;assign guide_expected_note=0;assign guide_expected_valid=0;assign guide_score_ready=1;
 song_guide #(.EXTERNAL_UI(1),.RHYTHM_ENABLE(1)) u_guide(.clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),.pause(test_owned || ui_page!=0 || menu_key_pause),
  .song_id(ui_song),.ui_start(ui_start),.ui_toggle(ui_toggle),.ui_restart(ui_restart),
  .keys({4'd0,performance_keys}),.ghost(1'b0),.active(guide_active),.done(guide_done),
  .cue_mask(cue_mask),.next_mask(next_mask),.wrong_mask(wrong_mask),
  .step_index(guide_step),.total_steps(guide_total),.beat_progress(beat_progress),
  .target_beats(target_beats),.beat_pulse(beat_pulse));
 end endgenerate
 generate if(GUIDE_MODES_ENABLE && PIANO_ROLL_ENABLE)begin:play_modes
 if(CHORD_SCORE_ENABLE)begin:chords
 guide_chord_modes modes(.clk(clk),.rst_n(rst_n),.mode(guide_mode),
  .running(guide_active && !guide_done),.suspended(guide_external_pause),
  .restart(ui_start || ui_restart),.score_ready(guide_score_ready),
  .expected_note(guide_expected_note),.expected_offsets(guide_expected_offsets),.expected_valid(guide_expected_valid),
  .step_index(guide_step),.midi_note_on(note_receipt),.midi_note(raw_receipt_note),.held_keys(piano_keys),
  .practice_hold(practice_hold),.demo_valid(guide_demo_valid),.demo_note(guide_demo_note),
  .demo_offsets(guide_demo_offsets),.demo_retrigger(guide_demo_retrigger));
 end else begin:single
 assign guide_demo_offsets=0;
 guide_play_modes modes(.clk(clk),.rst_n(rst_n),.mode(guide_mode),
  .running(guide_active && !guide_done),.suspended(guide_external_pause),
  .restart(ui_start || ui_restart),.score_ready(guide_score_ready),
  .expected_note(guide_expected_note),.expected_valid(guide_expected_valid),
  .step_index(guide_step),.midi_note_on(note_receipt),.midi_note(raw_receipt_note),
  .practice_hold(practice_hold),.demo_gate(),.demo_retrigger(),.demo_velocity(),
  .demo_valid(guide_demo_valid),.demo_note(guide_demo_note),.demo_note_retrigger(guide_demo_retrigger));
 end
 end else begin:no_play_modes
  assign guide_demo_offsets=0;assign practice_hold=0;assign guide_demo_valid=0;assign guide_demo_note=0;assign guide_demo_retrigger=0;
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
 hdmi_live_display #(.UI_ENABLE(1),.COMPACT_UI(1),.PIANO_ROLL_ENABLE(PIANO_ROLL_ENABLE),
  .HYBRID_MODE_ENABLE(1),.EXPRESSION_UI_ENABLE(1),.VISUALIZATION_ENABLE(1),.CUSTOM_SCORE_ENABLE(1),.SONG_LIBRARY_ENABLE(SONG_LIBRARY_ENABLE)) u_display(.clk27(clk),.rst_n(rst_n),.sample_tick(sample_tick),
  .custom_write_clk(clk),.custom_write_en(score_wr_en),.custom_write_addr(score_wr_addr),.custom_write_data(score_wr_data),.custom_config(custom_score_config),.custom_bank_ack(custom_pixel_bank_ack),
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
  .roll_active(guide_active),.roll_done(guide_done),.guide_mode(guide_mode),.practice_wait(practice_hold),
  .expression_adc(adc_values[31:0]),.expression_calibrated(pressure_calibrated),
  .midi_velocity(midi_velocity),.midi_bend(midi_bend),.midi_modulation(midi_modulation),
  .visual_voice0(visual_voice0),.visual_voice1(visual_voice1),
  .tmds_clk_p(tmds_clk_p),.tmds_clk_n(tmds_clk_n),
  .tmds_data_p(tmds_data_p),.tmds_data_n(tmds_data_n),
  .pll_locked(pll_locked),.frame_tick(frame_tick));
endmodule
