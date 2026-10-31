// Isolated on/off measurement: dynamic source and pixel inputs keep BOTH RAM
// copies live. All output fields are observed; no production gprj is touched.
module custom_score_resource_core #(parameter ENABLE=1)(
    input clk,pixel_clk,rst_n,sample_tick,pause,start,toggle,restart,frame,de,
    input [1:0] song,input [9:0] x,y,input [31:0] held,
    input we,input [8:0] wa,input [31:0] wd,cfg,
    output [23:0] rgb,output covered,ack,
    output [11:0] tick,cue,nextcue,output [1:0] selected,target,
    output active,done,valid,countin,pulse,
    output [6:0] note,output [5:0] step,steps,beats,output [7:0] progress
);
    piano_roll_guide #(.CUSTOM_SCORE_ENABLE(ENABLE)) guide(
        .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),.pause(pause),.song_id(song),
        .ui_start(start),.ui_toggle(toggle),.ui_restart(restart),.roll_tick(tick),
        .roll_song(selected),.active(active),.done(done),.expected_note(note),
        .expected_valid(valid),.step_index(step),.total_steps(steps),.total_beats(beats),
        .beat_progress(progress),.target_beats(target),.beat_pulse(pulse),
        .cue_mask(cue),.next_mask(nextcue),.count_in(countin),.custom_write_clk(clk),
        .custom_write_en(we),.custom_write_addr(wa),.custom_write_data(wd),.custom_config(cfg));
    // Pixel timing is dynamic, independent of source guide outputs: this
    // measures the datapaths, not a same-domain shortcut around wrapper CDC.
    piano_roll_renderer #(.CUSTOM_SCORE_ENABLE(ENABLE)) renderer(
        .pixel_clk(pixel_clk),.rst_n(rst_n),.x(x),.y(y),.de(de),.piano_keys(held),
        .piano_outside(pause),.roll_tick(wd[11:0]),.roll_song(song),.roll_active(start),
        .roll_done(restart),.rgb(rgb),.covered(covered),.frame_tick(frame),
        .custom_write_clk(clk),.custom_write_en(we),.custom_write_addr(wa),
        .custom_write_data(wd),.custom_config(cfg),.roll_custom_bank(toggle),.custom_bank_ack(ack));
endmodule
