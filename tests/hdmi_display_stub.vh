// Test boundary only: no claim about real TMDS/display lock.
module hdmi_live_display #(parameter UI_ENABLE=0,parameter COMPACT_UI=0,parameter PIANO_ROLL_ENABLE=0)(
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
 input [1:0] ui_page,ui_cursor,ui_song,input [3:0] ui_controls,
 input [1:0] control_page,fx_mode,input strum_mode,input [31:0] knob_values,
 input [31:0] piano_keys,input piano_outside,input [11:0] roll_tick,
 input [1:0] roll_song,input roll_active,roll_done);

 assign tmds_clk_p=0;assign tmds_clk_n=0;assign tmds_data_p=0;assign tmds_data_n=0;
 assign pll_locked=1;assign frame_tick=0;
endmodule
