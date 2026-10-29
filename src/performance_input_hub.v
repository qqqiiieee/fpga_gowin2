// 演奏输入汇合：本地键盘、独立MIDI、光束扫弦采用来源标签共用32声部。
// clk=27MHz，sample_tick=93750Hz音频使能；接口valid/ready均在clk域。
// 矩阵事件不能回压，先处理；MIDI及扫弦事件保持至ready，禁止丢失松键。
// 两滑杆与MIDI音量/弯音按最近一次变化取得控制权；CC1产生约6Hz颤音。
// 实体菜单/32路验证控制不由MIDI音符伪造；验证阶段取消外部演奏请求。
// 普通远程虚拟输入取得所有权时清声音，防止被覆盖来源留下持续门控。
module performance_input_hub #(
 parameter MIDI_ENABLE=0,parameter OPTICAL_ENABLE=0,parameter MIDI_CHANNEL=0,
 parameter PRESSURE_EXPRESSION_ENABLE=0
)(
 input clk,input rst_n,input sample_tick,input allow_performance,input suppress_controls,
 input remote_active,input digital_zero,input midi_rx,input[1:0] optical_beams,
 input local_on,input local_off,input[6:0] local_note,input[7:0] local_velocity,
 input[3:0] local_timbre,input[3:0] selected_timbre,input[15:0] local_keys,
 input[7:0] physical_volume,input signed[8:0] physical_pitch,
 output note_on,output note_off,output[6:0] note,output[7:0] velocity,
 output[3:0] timbre,output[1:0] event_source,
 output[7:0] volume,output signed[8:0] pitch,
 output program_valid,output[3:0] program_timbre,
 output midi_hit0,output midi_hit1,output[7:0] midi_drum_velocity0,output[7:0] midi_drum_velocity1,
 output panic_audio,output[11:0] performance_keys,
 output reg[6:0] primary_note,output reg primary_valid,output[13:0] diagnostic_status,
 input [7:0] pressure_vibrato
);
 wire m_valid,m_on,m_off,m_ready;wire[6:0] m_note;wire[7:0] m_velocity;
 wire[127:0] held;wire m_pc,m_timbre,m_volume_valid,m_bend_valid;
 wire[7:0] m_volume,m_count;wire signed[8:0] m_bend;wire[6:0] m_mod;
 wire m_panic,m_error,m_overflow;
 wire ext_suppress=!allow_performance || digital_zero || remote_active;
 generate if(MIDI_ENABLE)begin:midi_input
  midi_keyboard #(.MIDI_CHANNEL(MIDI_CHANNEL)) keyboard(
   .clk(clk),.rst_n(rst_n),.rx(midi_rx),.suppress(ext_suppress),.event_ready(m_ready),
   .event_valid(m_valid),.event_on(m_on),.event_off(m_off),.event_note(m_note),.event_velocity(m_velocity),
   .held_notes(held),.program_valid(m_pc),.timbre_select(m_timbre),
   .volume_valid(m_volume_valid),.volume(m_volume),.bend_valid(m_bend_valid),.bend(m_bend),
   .modulation(m_mod),.hit0(midi_hit0),.hit1(midi_hit1),
   .drum_velocity0(midi_drum_velocity0),.drum_velocity1(midi_drum_velocity1),
   .panic(m_panic),.framing_error(m_error),.overflow(m_overflow),.received_count(m_count));
 end else begin:no_midi
  assign m_valid=0;assign m_on=0;assign m_off=0;assign m_note=0;assign m_velocity=0;
  assign held=0;assign m_pc=0;assign m_timbre=0;assign m_volume_valid=0;assign m_volume=160;
  assign m_bend_valid=0;assign m_bend=0;assign m_mod=0;assign m_panic=0;assign m_error=0;
  assign m_overflow=0;assign m_count=0;assign midi_hit0=0;assign midi_hit1=0;
  assign midi_drum_velocity0=0;assign midi_drum_velocity1=0;
 end endgenerate
 wire o_valid,o_on,o_off,o_ready,o_busy,o_trigger,o_reverse,o_beam_ready;
 wire[6:0] o_note;wire[7:0] o_velocity,o_gesture_velocity;wire[3:0] o_gap;
 wire[1:0] o_blocked;
 // 全局panic必须同时取消旧扫弦，不能只清音频后又被播放器重新置gate。
 wire optical_suppress=ext_suppress || m_panic;
 generate if(OPTICAL_ENABLE)begin:optical_input
  optical_strum gesture(.clk(clk),.rst_n(rst_n),.beams(optical_beams),.suppress(optical_suppress),
   .trigger(o_trigger),.reverse(o_reverse),.velocity(o_gesture_velocity),.gap_ms(o_gap),
   .blocked(o_blocked),.ready(o_beam_ready));
  strum_player player(.clk(clk),.rst_n(rst_n),.trigger(o_trigger),.reverse(o_reverse),
   .velocity(o_gesture_velocity),.gap_ms(o_gap),.held_notes(held),.suppress(optical_suppress),
   .event_ready(o_ready),.event_valid(o_valid),.event_on(o_on),.event_off(o_off),
   .event_note(o_note),.event_velocity(o_velocity),.busy(o_busy));
 end else begin:no_optical
  assign o_valid=0;assign o_on=0;assign o_off=0;assign o_note=0;assign o_velocity=0;
  assign o_busy=0;assign o_trigger=0;assign o_reverse=0;assign o_beam_ready=0;
  assign o_gesture_velocity=0;assign o_gap=0;assign o_blocked=0;
 end endgenerate
 // V019的数字零参考会清空所有来源；零模式中不再缓存新的本地门控。
 wire local_event=(local_on || local_off) && !((MIDI_ENABLE || OPTICAL_ENABLE) && digital_zero);
 assign m_ready=!local_event && !ext_suppress;
 assign o_ready=!local_event && !m_valid && !optical_suppress;
 wire use_midi=!local_event && m_valid && !ext_suppress;
 wire use_optical=!local_event && !m_valid && o_valid && !optical_suppress;
 assign note_on=local_event?local_on:(use_midi?m_on:(use_optical?o_on:1'b0));
 assign note_off=local_event?local_off:(use_midi?m_off:(use_optical?o_off:1'b0));
 assign note=local_event?local_note:(use_midi?m_note:o_note);
 assign velocity=local_event?local_velocity:(use_midi?m_velocity:o_velocity);
 assign timbre=local_event?local_timbre:(use_midi?selected_timbre:4'd1);
 assign event_source=local_event?2'd0:(use_midi?2'd1:2'd2);
 assign program_valid=MIDI_ENABLE && m_pc && !suppress_controls && !remote_active;
 assign program_timbre={3'd0,m_timbre};
 reg previous_remote,previous_zero;
 always@(posedge clk or negedge rst_n)
  if(!rst_n)begin previous_remote<=0;previous_zero<=0;end
  else begin previous_remote<=remote_active;previous_zero<=digital_zero;end
 assign panic_audio=(MIDI_ENABLE && m_panic) ||
    ((MIDI_ENABLE || OPTICAL_ENABLE) &&
     ((remote_active && !previous_remote) || (digital_zero && !previous_zero)));
 // 最近改变的输入拥有音量/弯音。微小ADC漂移可能造成回切，前级滑杆已做平滑/死区。
 reg midi_owns_volume,midi_owns_pitch;
 reg midi_volume_seen,midi_pitch_seen;
 reg[7:0] last_physical_volume,saved_midi_volume;
 reg signed[8:0] last_physical_pitch,saved_midi_pitch;
 reg[23:0] vibrato_phase;
 always@(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   midi_owns_volume<=0;midi_owns_pitch<=0;midi_volume_seen<=0;midi_pitch_seen<=0;
   last_physical_volume<=160;last_physical_pitch<=0;
   saved_midi_volume<=160;saved_midi_pitch<=0;vibrato_phase<=0;
  end else begin
   last_physical_volume<=physical_volume;last_physical_pitch<=physical_pitch;
   if(physical_volume!=last_physical_volume || remote_active)midi_owns_volume<=0;
   if(physical_pitch!=last_physical_pitch || remote_active)midi_owns_pitch<=0;
   if(MIDI_ENABLE && m_volume_valid && !ext_suppress && !m_panic)begin
    if(!midi_volume_seen || m_volume!=saved_midi_volume)midi_owns_volume<=1;
    saved_midi_volume<=m_volume;midi_volume_seen<=1;
   end
   if(MIDI_ENABLE && m_bend_valid && !ext_suppress && !m_panic)begin
    if(!midi_pitch_seen || m_bend!=saved_midi_pitch)midi_owns_pitch<=1;
    saved_midi_pitch<=m_bend;midi_pitch_seen<=1;
   end
   if(m_panic)begin
    midi_owns_volume<=0;midi_owns_pitch<=0;midi_volume_seen<=0;midi_pitch_seen<=0;
    saved_midi_volume<=160;saved_midi_pitch<=0;
   end
   if(sample_tick)vibrato_phase<=vibrato_phase+24'd1074;
  end
 end
 assign volume=midi_owns_volume?saved_midi_volume:physical_volume;
 wire signed[8:0] base_pitch=midi_owns_pitch?saved_midi_pitch:physical_pitch;
 wire[6:0] folded_phase=vibrato_phase[23]?~vibrato_phase[22:16]:vibrato_phase[22:16];
 wire signed[7:0] triangle=$signed({1'b0,folded_phase})-8'sd64;
 // FSR揉弦最大约±128弯音码（约±1半音）；CC1仍保留旧最大约±64码。
 // 两来源取较大深度而非叠加，避免同时操作时深度突增；基础音高仍由滑杆/Bend决定。
 // 虚拟ADC也能模拟FSR，所以远程接管只禁用MIDI表达，不屏蔽已选中的压力表情。
 wire [7:0] pressure_depth=(PRESSURE_EXPRESSION_ENABLE && allow_performance && !digital_zero)?pressure_vibrato:8'd0;
 wire [7:0] midi_depth=(MIDI_ENABLE && !ext_suppress)?{1'b0,m_mod}:8'd0;
 wire [7:0] vibrato_depth=(pressure_depth>midi_depth)?pressure_depth:midi_depth;
 wire signed[16:0] vibrato_product=triangle*$signed({1'b0,vibrato_depth});
 wire signed[8:0] vibrato_offset=vibrato_product>>>7;
 wire signed[9:0] pitch_sum=$signed(base_pitch)+$signed(vibrato_offset);
 assign pitch=(pitch_sum>255)?9'sd255:((pitch_sum< -256)?-9'sd256:pitch_sum[8:0]);
 // 显示/跟弹保留原12个琴键位置，对应的MIDI音符可直接跟弹原三首曲子。
 function[6:0] mapped_note;input integer i;begin case(i)
 0:mapped_note=60;1:mapped_note=62;2:mapped_note=64;3:mapped_note=65;
 4:mapped_note=67;5:mapped_note=69;6:mapped_note=71;7:mapped_note=72;
 8:mapped_note=74;9:mapped_note=76;10:mapped_note=77;default:mapped_note=79;
 endcase end endfunction
 genvar g;generate for(g=0;g<12;g=g+1)begin:display_keys
  assign performance_keys[g]=local_keys[g] || held[mapped_note(g)];
 end endgenerate
 // 代表音符顺序扫描，约4.74us更新一遍，避免128路组合优先编码器增加布局压力。
 reg[6:0] search_index,candidate_note,optical_last_note;reg candidate_valid;
 always@(posedge clk or negedge rst_n)begin
  if(!rst_n)begin search_index<=0;candidate_note<=0;candidate_valid<=0;primary_note<=0;primary_valid<=0;optical_last_note<=60;end
  else begin
   if(o_valid && o_ready && o_on)optical_last_note<=o_note;
   if(held[search_index])begin candidate_note<=search_index;candidate_valid<=1;end
   if(search_index==127)begin
    primary_note<=held[127]?7'd127:(candidate_valid?candidate_note:optical_last_note);
    primary_valid<=held[127] || candidate_valid || o_busy;
    candidate_valid<=0;search_index<=0;
   end else search_index<=search_index+1'b1;
  end
 end
 // 此14位拼到09诊断diag2[15:2]；低两位仍为触摸valid/fault，兼容原标定工具。
 assign diagnostic_status={7'd0,o_busy,o_beam_ready,m_overflow,o_blocked,m_error,(|held || m_count!=0)};
endmodule
