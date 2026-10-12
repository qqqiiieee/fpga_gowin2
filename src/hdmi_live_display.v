// 显示封装：源域27MHz、像素25.2MHz、DDR串行126MHz；锁定后各域分别释放复位。
// sample_tick是源域时钟使能，pcm为16位二补码；pixel域只读取整帧状态与双缓冲波形。
// UI_ENABLE默认0保留242bit旧接口，生产1增加高10bit页/游标/曲目/控制键。
// 低242bit打包与解包顺序必须匹配，见下方布局；不要为多位状态逐位双触发器同步。
// source_status由req/ack整包握手捕获，display_status仅frame_tick帧边界切换。
// wave_scope RAM同步读一拍、字体ROM一拍、RGB寄存一拍，DE/HS/VS必须共同延迟三拍。
// 复位立即断言且每域同步释放；PLL失锁清空显示状态但不复位音频层。
// peak保留接口但当前波形缩放取capture_peak；不要为了消除未用端口而改所有位置调用。
// 输出为兼容DVI的视频TMDS，没有HDMI音频包、HDCP或USB触控。

// Instrument status crosses domains as a coherent frame-boundary snapshot.
// The scope uses immutable RAM banks with its own request/ack handshake.
module hdmi_live_display #(parameter UI_ENABLE=0)(
 input clk27,input rst_n,input sample_tick,input [15:0] pcm,peak,
 input [11:0] keys,input [3:0] timbre,input [6:0] note,input note_valid,
 input [15:0] frequency_bcd,input [7:0] volume_percent,
 input signed [7:0] level_dbfs,input [7:0] peak_percent,
 input signed [8:0] pitch,input [5:0] voices,input [7:0] pressure0,pressure1,flags,
 input guide_active,guide_done,input [11:0] cue_mask,next_mask,wrong_mask,
 input [5:0] guide_step,guide_total,input [7:0] beat_progress,
 input [1:0] target_beats,input clip,
 output tmds_clk_p,tmds_clk_n,output [2:0] tmds_data_p,tmds_data_n,
 output pll_locked,output frame_tick,
 // 测试页新增 78 位：1+6+32+32+1+5+1；全部由音频源时钟域的父模块提供。
 // test_active 表示测试引擎持有音频通路，包含进入/退出交接，不能仅接测试按键。
 // requested 为请求振荡器数（0..32）；busy/gate 的 bit i 对应第 i 路（0..31）。
 // busy 包含释放尾音；gate 是当前门控请求，两者必须分别显示。
 // sweep/index 为扫频模式和当前 0..31 索引；overrun 是测试调度超时状态。
 // voices 在测试期间应由父模块对 busy 计数，保持“请求数/实际活动数”的区别。
 input test_active,input [5:0] test_requested,
 input [31:0] test_busy,test_gate,input test_sweep,
 input [4:0] test_index,input test_overrun,
 input [1:0] ui_page,ui_cursor,ui_song,input [3:0] ui_controls);
 wire serial_clk,pixel_clk;
 hdmi_clocks u_clocks(clk27,rst_n,serial_clk,pixel_clk,pll_locked);
 wire common_reset_n=rst_n && pll_locked;
 (* syn_preserve=1 *) reg [2:0] source_reset_sync,pixel_reset_sync;
 always @(posedge clk27 or negedge common_reset_n)
  if(!common_reset_n)source_reset_sync<=0;
  else source_reset_sync<={source_reset_sync[1:0],1'b1};
 always @(posedge pixel_clk or negedge common_reset_n)
  if(!common_reset_n)pixel_reset_sync<=0;
  else pixel_reset_sync<={pixel_reset_sync[1:0],1'b1};
 wire video_rst_n=pixel_reset_sync[2];
 wire [9:0] x,y;
 wire de,hsync,vsync;
 video_timing u_timing(pixel_clk,video_rst_n,x,y,de,hsync,vsync,frame_tick);
 // 原乐器/教学状态 164 位 + 测试状态 78 位 = 242 位。
 // 不能对新增字段逐位同步：页面所有权、掩码、计数、索引必须来自同一次握手快照。
 // 原字段顺序不变；测试字段追加到低 78 位，打包和解包严格使用同一顺序。
 // 低位布局：[77] active，[76:71] requested，[70:39] busy，[38:7] gate，
 // [6] sweep，[5:1] index，[0] overrun；仅在帧边界使用已应答的整包数据。
 localparam STATUS_WIDTH=164+78+(UI_ENABLE ? 10 : 0);
 wire [241:0] legacy_source_status={
  keys,timbre,note,note_valid,frequency_bcd,volume_percent,level_dbfs,peak_percent,
  pitch,voices,pressure0,pressure1,flags,guide_active,guide_done,cue_mask,next_mask,
  wrong_mask,guide_step,guide_total,beat_progress,target_beats,clip,
  test_active,test_requested,test_busy,test_gate,test_sweep,test_index,test_overrun};
 // 旧 242-bit 接口与四页 252-bit 接口显式选择，消除隐式截断依赖。
 wire [STATUS_WIDTH-1:0] source_status;
 generate if(UI_ENABLE)begin:source_ui_packet
  assign source_status={ui_page,ui_cursor,ui_song,ui_controls,legacy_source_status};
 end else begin:source_legacy_packet
  assign source_status=legacy_source_status;
 end endgenerate
 wire [STATUS_WIDTH-1:0] display_status;
 hdmi_status_cdc #(.WIDTH(STATUS_WIDTH)) u_status(clk27,source_reset_sync[2],source_status,
  pixel_clk,video_rst_n,frame_tick,display_status);
 wire [11:0] d_keys,d_cue,d_next,d_wrong;
 wire [3:0] d_timbre;
 wire [6:0] d_note;
 wire d_note_valid,d_active,d_done,d_clip;
 wire [15:0] d_frequency;
 wire [7:0] d_volume,d_peak,d_pressure0,d_pressure1,d_flags,d_progress;
 wire signed [7:0] d_level;
 wire signed [8:0] d_pitch;
 wire [5:0] d_voices,d_step,d_total;
 wire [1:0] d_beats;
 wire d_test_active,d_test_sweep,d_test_overrun;
 wire [5:0] d_test_requested;
 wire [31:0] d_test_busy,d_test_gate;
 wire [4:0] d_test_index;
 assign {d_keys,d_timbre,d_note,d_note_valid,d_frequency,d_volume,d_level,d_peak,
  d_pitch,d_voices,d_pressure0,d_pressure1,d_flags,d_active,d_done,d_cue,d_next,
  d_wrong,d_step,d_total,d_progress,d_beats,d_clip,
  d_test_active,d_test_requested,d_test_busy,d_test_gate,
  d_test_sweep,d_test_index,d_test_overrun}=display_status[241:0];
 // d_test_* 只在帧边界更新；过渡期间仍显示 OSC TEST，避免半帧混入普通页面。
 // Physical clipping and audio engine overrun share the ALERT flag in the UI.
 wire [7:0] alert_flags=d_flags | (d_clip?8'h80:8'h00);
 wire [7:0] scope_addr=(x-10'd32)>>1;
 wire signed [15:0] scope_current,scope_previous;
 wire [3:0] scope_gain;
 wire scope_valid;
 wave_scope u_scope(clk27,source_reset_sync[2],sample_tick,pcm,
  pixel_clk,video_rst_n,frame_tick,scope_addr,scope_current,scope_previous,scope_gain,scope_valid);
 // RAM has one synchronous read cycle. Raster and control follow that delay.
 reg [9:0] draw_x,draw_y;
 reg draw_de,draw_hs,draw_vs;
 always @(posedge pixel_clk or negedge video_rst_n)begin
  if(!video_rst_n)begin draw_x<=0;draw_y<=0;draw_de<=0;draw_hs<=1;draw_vs<=1;end
  else begin draw_x<=x;draw_y<=y;draw_de<=de;draw_hs<=hsync;draw_vs<=vsync;end
 end
 wire [7:0] r,g,b;
 wire [1:0] d_ui_page,d_ui_cursor,d_ui_song;
 wire [3:0] d_ui_controls;
 generate if(UI_ENABLE)begin:ui_metadata
  assign {d_ui_page,d_ui_cursor,d_ui_song,d_ui_controls}=display_status[251:242];
 end else begin:legacy_metadata
  assign {d_ui_page,d_ui_cursor,d_ui_song,d_ui_controls}=10'd0;
 end endgenerate
 hdmi_instrument_dashboard #(.UI_ENABLE(UI_ENABLE)) u_dashboard(
  .x(draw_x),.y(draw_y),.de(draw_de),.keys(d_keys),.timbre(d_timbre),
  .note(d_note),.note_valid(d_note_valid),.frequency_bcd(d_frequency),
  .volume_percent(d_volume),.level_dbfs(d_level),.peak_percent(d_peak),
  .pitch(d_pitch),.voices(d_voices),.pressure0(d_pressure0),.pressure1(d_pressure1),
  .flags(alert_flags),.guide_active(d_active),.guide_done(d_done),
  .cue_mask(d_cue),.next_mask(d_next),.wrong_mask(d_wrong),
  .guide_step(d_step),.guide_total(d_total),.beat_progress(d_progress),.target_beats(d_beats),
  .wave_current(scope_current),.wave_previous(scope_previous),
  .scope_gain(scope_gain),.wave_valid(scope_valid),.red(r),.green(g),.blue(b),
  .test_active(d_test_active),.test_requested(d_test_requested),
  .test_busy(d_test_busy),.test_gate(d_test_gate),.test_sweep(d_test_sweep),
  .test_index(d_test_index),.test_overrun(d_test_overrun),
  .pixel_clk(pixel_clk),.rst_n(video_rst_n),
  .ui_page(d_ui_page),.ui_cursor(d_ui_cursor),.ui_song(d_ui_song),.ui_controls(d_ui_controls));
 // 中文字模BRAM新增一拍；同步信号跟随字模背景同拍延迟。
 reg font_de,font_hs,font_vs;
 always @(posedge pixel_clk or negedge video_rst_n)begin
  if(!video_rst_n)begin font_de<=0;font_hs<=1;font_vs<=1;end
  else begin font_de<=draw_de;font_hs<=draw_hs;font_vs<=draw_vs;end
 end
 reg [23:0] rgb_pipe;
 reg de_pipe,hs_pipe,vs_pipe;
 always @(posedge pixel_clk or negedge video_rst_n)begin
  if(!video_rst_n)begin rgb_pipe<=0;de_pipe<=0;hs_pipe<=1;vs_pipe<=1;end
  else begin rgb_pipe<={r,g,b};de_pipe<=font_de;hs_pipe<=font_hs;vs_pipe<=font_vs;end
 end
 hdmi_tx u_tx(pixel_clk,serial_clk,video_rst_n,rgb_pipe[23:16],rgb_pipe[15:8],
  rgb_pipe[7:0],de_pipe,hs_pipe,vs_pipe,tmds_clk_p,tmds_clk_n,tmds_data_p,tmds_data_n);
endmodule
