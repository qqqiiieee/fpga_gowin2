`include "src/piano_layout.vh"
// 演奏输入汇合：本地键盘、独立MIDI、光束扫弦采用来源标签共用32声部。
// clk=27MHz，sample_tick=93750Hz音频使能；接口valid/ready均在clk域。
// 矩阵事件不能回压，先处理；MIDI及扫弦事件保持至ready，禁止丢失松键。
// 两滑杆与MIDI音量/弯音按最近一次变化取得控制权；CC1产生约6Hz颤音。
// 实体菜单/32路验证控制不由MIDI音符伪造；验证阶段取消外部演奏请求。
// 普通远程虚拟输入取得所有权时清声音，防止被覆盖来源留下持续门控。
module performance_input_hub #(
 parameter MIDI_ENABLE=0,parameter OPTICAL_ENABLE=0,parameter MIDI_CHANNEL=0,
 parameter PRESSURE_EXPRESSION_ENABLE=0,parameter CONTROL_BANK_ENABLE=0,parameter PHONE_VOLUME_ENABLE=0,parameter MAPPING_ENABLE=0
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
 input [7:0] pressure_vibrato,
 // V021控制侧与演奏侧分离：UI只改参数/模式；不伪造本地音符。
 input [1:0] strum_mode,input manual_panic,input knob_volume_valid,input [7:0] knob_volume,
 output cc_valid,output [6:0] cc_number,cc_value,
 output hat_closed_hit,hat_open_hit,output [7:0] hat_closed_velocity,hat_open_velocity,
 // 只读实体MIDI按住监视：默认bit0=MIDI41(F2)，bit31=MIDI72(C5)，统一由piano_layout.vh指定，半音逐位。
 // 不并入本地/触摸/虚拟键，不显示已松键的延音或扫弦尾音；范围外另置标志。
 output [31:0] monitor_piano_keys32,output monitor_piano_outside,
 // 只读演奏诊断：最近一次交付的旋律Note On原始力度，以及解析器弯音/CC1。
 // 力度0..127（音频内部扩展为0..255）；弯音为归一化9位码，不是Hz。
 output reg [7:0] monitor_midi_velocity,
 output signed [8:0] monitor_midi_bend,output [6:0] monitor_midi_modulation,
    // Mapping config is staged externally. Inputs must be stable at commit handshake.
    // addr={bank,index[6:0]}; writes/commit are accepted ONLY with their ready high.
    input wire mapping_enable, mapping_bank, mapping_commit,
    input wire mapping_wr_en, input wire [7:0] mapping_wr_addr,
    input wire [6:0] mapping_wr_data,
    input wire [27:0] mapping_pad_notes, mapping_cc_numbers,
    output wire mapping_wr_ready, mapping_commit_ready, mapping_commit_ack,
    output wire monitor_note_receipt, output wire [6:0] monitor_raw_note
);
 wire raw_receipt;
 assign monitor_note_receipt=raw_receipt && !global_cancel;
 wire m_valid,m_on,m_off,m_ready;wire[6:0] m_note;wire[7:0] m_velocity;
 wire[127:0] held;wire m_pc,m_timbre,m_volume_valid,m_bend_valid;
 // 复用解析器held别名，不新增按键状态或改变抑制、panic、音频仲裁语义。
 // MIDI_ENABLE=0时既有no_midi分支将held置零，两个监视口自然恒为零。
 assign monitor_piano_keys32=held[`PIANO_BASE_NOTE +: 32];
 assign monitor_piano_outside=(|held[`PIANO_BASE_NOTE-1:0]) || (|held[127:`PIANO_LAST_NOTE+1]);
 wire[7:0] m_volume,m_count;wire signed[8:0] m_bend;wire[6:0] m_mod;
 wire m_panic,m_error,m_overflow;
 assign monitor_midi_bend=m_bend;
 assign monitor_midi_modulation=m_mod;
 wire m_cc_valid;wire [6:0] m_cc_number,m_cc_value;
 wire m_hit0,m_hit1;wire [7:0] m_drum_velocity0,m_drum_velocity1;
 wire h_closed,h_open;wire [7:0] h_closed_velocity,h_open_velocity;
 wire user_panic=CONTROL_BANK_ENABLE && manual_panic;
 reg [1:0] previous_strum;
 always @(posedge clk or negedge rst_n)
  if(!rst_n)previous_strum<=0;else previous_strum<=strum_mode;
 wire mode_changed=CONTROL_BANK_ENABLE && (strum_mode!=previous_strum);
 wire ext_suppress=!allow_performance || digital_zero || remote_active;
 always @(posedge clk or negedge rst_n)
  if(!rst_n)monitor_midi_velocity<=0;
  else if(m_panic || user_panic)monitor_midi_velocity<=0;
  else if(m_valid && m_ready && m_on && !ext_suppress)
   monitor_midi_velocity<={1'b0,m_velocity[7:1]};
 // V021全局取消优先于已挂起的新控制/Pad请求；只门控交付，不改解析器状态。
 // 参数0恒为不取消，保持历史实例的控制仲裁、脉冲和力度语义。
 wire global_cancel=CONTROL_BANK_ENABLE && (ext_suppress || panic_audio);
 generate if(MIDI_ENABLE)begin:midi_input
  midi_keyboard #(.MIDI_CHANNEL(MIDI_CHANNEL),.MAPPING_ENABLE(MAPPING_ENABLE)) keyboard(
        .mapping_enable(mapping_enable),.mapping_bank(mapping_bank),.mapping_commit(mapping_commit),
        .mapping_wr_en(mapping_wr_en),.mapping_wr_addr(mapping_wr_addr),.mapping_wr_data(mapping_wr_data),
        .mapping_pad_notes(mapping_pad_notes),.mapping_cc_numbers(mapping_cc_numbers),
        .mapping_wr_ready(mapping_wr_ready),.mapping_commit_ready(mapping_commit_ready),
        .mapping_commit_ack(mapping_commit_ack),
   .clk(clk),.rst_n(rst_n),.rx(midi_rx),.suppress(ext_suppress || user_panic),.event_ready(m_ready),
   .event_valid(m_valid),.event_on(m_on),.event_off(m_off),.event_note(m_note),.event_velocity(m_velocity),
   .receipt_note_on(raw_receipt),.receipt_note(monitor_raw_note),
   .held_notes(held),.program_valid(m_pc),.timbre_select(m_timbre),
   .volume_valid(m_volume_valid),.volume(m_volume),.bend_valid(m_bend_valid),.bend(m_bend),
   .modulation(m_mod),.hit0(m_hit0),.hit1(m_hit1),
   .drum_velocity0(m_drum_velocity0),.drum_velocity1(m_drum_velocity1),
   .panic(m_panic),.framing_error(m_error),.overflow(m_overflow),.received_count(m_count),
   .cc_valid(m_cc_valid),.cc_number(m_cc_number),.cc_value(m_cc_value),
   .hat_closed_hit(h_closed),.hat_open_hit(h_open),
   .hat_closed_velocity(h_closed_velocity),.hat_open_velocity(h_open_velocity));
 end else begin:no_midi
  assign raw_receipt=0;assign monitor_raw_note=0;
  assign mapping_wr_ready=0;assign mapping_commit_ready=0;assign mapping_commit_ack=0;
  assign m_valid=0;assign m_on=0;assign m_off=0;assign m_note=0;assign m_velocity=0;
  assign held=0;assign m_pc=0;assign m_timbre=0;assign m_volume_valid=0;assign m_volume=160;
  assign m_bend_valid=0;assign m_bend=0;assign m_mod=0;assign m_panic=0;assign m_error=0;
  assign m_overflow=0;assign m_count=0;assign m_hit0=0;assign m_hit1=0;
  assign m_drum_velocity0=0;assign m_drum_velocity1=0;
  assign m_cc_valid=0;assign m_cc_number=0;assign m_cc_value=0;
  assign h_closed=0;assign h_open=0;assign h_closed_velocity=0;assign h_open_velocity=0;
 end endgenerate
 assign cc_valid=m_cc_valid && !suppress_controls && !user_panic && !global_cancel;
 assign cc_number=m_cc_number;assign cc_value=m_cc_value;
 // 解析器先接内部wire，Hub各输出只有这里一个驱动；取消时脉冲和力度同清零。
 assign midi_hit0=m_hit0 && !global_cancel;assign midi_hit1=m_hit1 && !global_cancel;
 assign midi_drum_velocity0=global_cancel?8'd0:m_drum_velocity0;
 assign midi_drum_velocity1=global_cancel?8'd0:m_drum_velocity1;
 assign hat_closed_hit=h_closed && !global_cancel;assign hat_open_hit=h_open && !global_cancel;
 assign hat_closed_velocity=global_cancel?8'd0:h_closed_velocity;
 assign hat_open_velocity=global_cancel?8'd0:h_open_velocity;
 wire o_valid,o_on,o_off,o_ready,o_busy,o_trigger,o_reverse,o_beam_ready;
 wire[6:0] o_note;wire[7:0] o_velocity,o_gesture_velocity;wire[3:0] o_gap;
 wire[1:0] o_blocked,o_electrical;
 // 全局panic必须同时取消旧扫弦，不能只清音频后又被播放器重新置gate。
 // 模式0 KEY仅转发MIDI；模式1 STRUM保留held选和弦，消费但不转发MIDI音符。
 // 模式2 HYBRID同时转发两路：MIDI用source1/所选音色，光电用source2/拨弦音色。
 // 不增加振荡器：两来源共用32声部，来源标签使同音的松键/扫弦收尾互不误关。
 // 切模式清旧声部/扫弦队列，避免两个模式的尾音和所有权互相遗留。
 wire optical_suppress=ext_suppress || m_panic || user_panic || mode_changed ||
    (CONTROL_BANK_ENABLE && strum_mode==0);
 generate if(OPTICAL_ENABLE)begin:optical_input
  optical_strum gesture(.clk(clk),.rst_n(rst_n),.beams(optical_beams),.suppress(optical_suppress),
   .trigger(o_trigger),.reverse(o_reverse),.velocity(o_gesture_velocity),.gap_ms(o_gap),
   .blocked(o_blocked),.ready(o_beam_ready),.electrical_level(o_electrical));
  strum_player player(.clk(clk),.rst_n(rst_n),.trigger(o_trigger),.reverse(o_reverse),
   .velocity(o_gesture_velocity),.gap_ms(o_gap),.held_notes(held),.suppress(optical_suppress),
   .event_ready(o_ready),.event_valid(o_valid),.event_on(o_on),.event_off(o_off),
   .event_note(o_note),.event_velocity(o_velocity),.busy(o_busy));
 end else begin:no_optical
  assign o_valid=0;assign o_on=0;assign o_off=0;assign o_note=0;assign o_velocity=0;
  assign o_busy=0;assign o_trigger=0;assign o_reverse=0;assign o_beam_ready=0;
  assign o_gesture_velocity=0;assign o_gap=0;assign o_blocked=0;assign o_electrical=0;
 end endgenerate
 // V019的数字零参考会清空所有来源；零模式中不再缓存新的本地门控。
 wire local_event=(local_on || local_off) && !((MIDI_ENABLE || OPTICAL_ENABLE) && digital_zero);
 assign m_ready=!local_event && !ext_suppress;
 assign o_ready=!local_event && !m_valid && !optical_suppress;
 wire use_midi=!local_event && m_valid && !ext_suppress &&
    !(CONTROL_BANK_ENABLE && strum_mode==1);
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
 assign panic_audio=user_panic || mode_changed || (MIDI_ENABLE && m_panic) ||
    ((MIDI_ENABLE || OPTICAL_ENABLE) &&
     ((remote_active && !previous_remote) || (digital_zero && !previous_zero)));
 // 最近改变的输入拥有音量/弯音。微小ADC漂移可能造成回切，前级滑杆已做平滑/死区。
 reg midi_owns_volume,midi_owns_pitch;
 reg midi_volume_seen,midi_pitch_seen;
 reg[7:0] last_physical_volume,saved_midi_volume;
 reg [7:0] physical_volume_anchor;
 wire [7:0] physical_volume_distance=physical_volume>=physical_volume_anchor?
    physical_volume-physical_volume_anchor:physical_volume_anchor-physical_volume;
 reg signed[8:0] last_physical_pitch,saved_midi_pitch;
 reg[23:0] vibrato_phase;
 always@(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   midi_owns_volume<=0;midi_owns_pitch<=0;midi_volume_seen<=0;midi_pitch_seen<=0;
   last_physical_volume<=160;physical_volume_anchor<=160;last_physical_pitch<=0;
   saved_midi_volume<=160;saved_midi_pitch<=0;vibrato_phase<=0;
  end else begin
   last_physical_volume<=physical_volume;last_physical_pitch<=physical_pitch;
   // 有MIDI旋钮时，ADC在1~3码范围内的微抖不能反复夺走音量控制。
   // 使用最后确认位置作锚，而不是逐拍位置，缓慢移动累计越过4码仍能接管。
   if(CONTROL_BANK_ENABLE)begin
    if(physical_volume_distance>=4 || remote_active)begin
     physical_volume_anchor<=physical_volume;midi_owns_volume<=0;
    end
   end else if(physical_volume!=last_physical_volume || remote_active)midi_owns_volume<=0;
   if(physical_pitch!=last_physical_pitch || remote_active)midi_owns_pitch<=0;
   if(MIDI_ENABLE && m_volume_valid && !ext_suppress && !m_panic && !global_cancel)begin
    if(!midi_volume_seen || m_volume!=saved_midi_volume)begin
     midi_owns_volume<=1;
     // 从当前真实滑杆位置重新累计4码，避免旧锚点把1码抖动判成夺权。
     if(CONTROL_BANK_ENABLE)physical_volume_anchor<=physical_volume;
    end
    saved_midi_volume<=m_volume;midi_volume_seen<=1;
   end
   // V031此入口合并手机绝对SET与已软接管且变化的K4总音量请求。
   // 手机显式SET允许重新取得所有权；K4重复/未接管值由控制库抑制，不发请求。
   // 默认参数0保留旧调用语义；PHONE_VOLUME_ENABLE由手机输入层选1，CC7路径不变。
   if(CONTROL_BANK_ENABLE && knob_volume_valid && !ext_suppress && !m_panic && !global_cancel)begin
    if(PHONE_VOLUME_ENABLE || !midi_volume_seen || knob_volume!=saved_midi_volume)begin
     midi_owns_volume<=1;physical_volume_anchor<=physical_volume;
    end
    saved_midi_volume<=knob_volume;midi_volume_seen<=1;
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
 // V021的第二路压力另送包络阻尼；不再同时叠加揉弦，摇杆Y/CC1独占颤音深度。
 wire [7:0] pressure_depth=(PRESSURE_EXPRESSION_ENABLE && !CONTROL_BANK_ENABLE && allow_performance && !digital_zero)?pressure_vibrato:8'd0;
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
 assign diagnostic_status={4'd0,(OPTICAL_ENABLE!=0),o_electrical,o_busy,o_beam_ready,m_overflow,o_blocked,m_error,(|held || m_count!=0)};
endmodule
