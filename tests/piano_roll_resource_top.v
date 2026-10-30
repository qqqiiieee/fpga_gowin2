// Isolated synthesis comparison: same compact dashboard and coherent CDC,
// all telemetry dynamic, feature off versus on. No top/audio/project mutation.
module piano_roll_resource_core #(parameter ENABLE=0)(
    input source_clk,pixel_clk,rst_n,frame,de,input [9:0] x,y,
    input [337:0] source_status,input signed [15:0] wave_current,wave_previous,
    input [3:0] scope_gain,input wave_valid,output [23:0] rgb
);
    localparam WIDTH=289+49*ENABLE;
    wire [WIDTH-1:0] packet;
    hdmi_status_cdc #(.WIDTH(WIDTH)) u_status(source_clk,rst_n,source_status[WIDTH-1:0],
        pixel_clk,rst_n,frame,packet);
    wire [48:0] piano;
    generate if(ENABLE)begin assign piano=packet[337:289];end
    else begin assign piano=49'd0;end endgenerate
    hdmi_compact_dashboard #(.PIANO_ROLL_ENABLE(ENABLE)) u_dashboard(
        .pixel_clk(pixel_clk),.rst_n(rst_n),.x(x),.y(y),.de(de),
        .keys(packet[241:230]),.timbre(packet[229:226]),.note(packet[225:219]),
        .note_valid(packet[218]),.frequency_bcd(packet[217:202]),
        .volume_percent(packet[201:194]),.level_dbfs(packet[193:186]),
        .peak_percent(packet[185:178]),.voices(packet[168:163]),.flags(packet[146:139]),
        .cue_mask(packet[136:125]),.next_mask(packet[124:113]),.wrong_mask(packet[112:101]),
        .guide_step(packet[100:95]),.guide_total(packet[94:89]),
        .wave_current(wave_current),.wave_previous(wave_previous),.scope_gain(scope_gain),.wave_valid(wave_valid),
        .test_active(packet[77]),.test_requested(packet[76:71]),.test_busy(packet[70:39]),.test_gate(packet[38:7]),
        .test_sweep(packet[6]),.test_index(packet[5:1]),.test_overrun(packet[0]),
        .ui_page(packet[251:250]),.ui_cursor(packet[249:248]),.ui_song(packet[247:246]),.ui_controls(packet[245:242]),
        .control_page(packet[288:287]),.fx_mode(packet[286:285]),.strum_mode(packet[284]),.knob_values(packet[283:252]),
        .piano_keys(piano[48:17]),.piano_outside(piano[16]),.roll_tick(piano[15:4]),.roll_song(piano[3:2]),
        .roll_active(piano[1]),.roll_done(piano[0]),.red(rgb[23:16]),.green(rgb[15:8]),.blue(rgb[7:0]));
endmodule

module piano_roll_resource_off(
    input source_clk,pixel_clk,rst_n,frame,de,input [9:0] x,y,
    input [337:0] source_status,input signed [15:0] wave_current,wave_previous,
    input [3:0] scope_gain,input wave_valid,output [23:0] rgb);
    piano_roll_resource_core #(.ENABLE(0)) core(.source_clk(source_clk),.pixel_clk(pixel_clk),
        .rst_n(rst_n),.frame(frame),.de(de),.x(x),.y(y),.source_status(source_status),
        .wave_current(wave_current),.wave_previous(wave_previous),.scope_gain(scope_gain),
        .wave_valid(wave_valid),.rgb(rgb));
endmodule
module piano_roll_resource_on(
    input source_clk,pixel_clk,rst_n,frame,de,input [9:0] x,y,
    input [337:0] source_status,input signed [15:0] wave_current,wave_previous,
    input [3:0] scope_gain,input wave_valid,output [23:0] rgb);
    piano_roll_resource_core #(.ENABLE(1)) core(.source_clk(source_clk),.pixel_clk(pixel_clk),
        .rst_n(rst_n),.frame(frame),.de(de),.x(x),.y(y),.source_status(source_status),
        .wave_current(wave_current),.wave_previous(wave_previous),.scope_gain(scope_gain),
        .wave_valid(wave_valid),.rgb(rgb));
endmodule
