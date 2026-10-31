`timescale 1ns/1ps
// Compare ENABLE=1 against the frozen pre-edit guide, not another instance of
// the modified implementation. All three complete songs, fractional timing,
// pauses/toggles/restarts and arbitrary config traffic must be bit-identical.
module tb_custom_builtin_compat;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,sample=0,pause=0,start=0,toggle=0,restart=0;
    reg [1:0] song=0;
    reg [31:0] cfg=0;
    wire [77:0] a,b;
    reg [31:0] rng=32'h31415926;
    reg [9:0] x=0,y=0;
    reg [11:0] pixel_tick=0;
    wire [23:0] pixel_a,pixel_b;
    wire cover_a,cover_b;
`define RENDER_PORTS \
    .pixel_clk(clk),.rst_n(rst_n),.x(x),.y(y),.de(rng[20]), \
    .piano_keys(rng),.piano_outside(rng[21]),.roll_tick(pixel_tick), \
    .roll_song(song),.roll_active(rng[22]),.roll_done(rng[23])
    piano_roll_renderer #(.CUSTOM_SCORE_ENABLE(1)) pixel_dut(`RENDER_PORTS,
        .rgb(pixel_a),.covered(cover_a),.custom_write_clk(clk),.custom_write_en(1'b0),
        .custom_write_addr(9'd0),.custom_write_data(32'd0),.custom_config(cfg),
        .frame_tick(rng[24]),.roll_custom_bank(rng[25]));
    piano_roll_renderer_baseline pixel_golden(`RENDER_PORTS,.rgb(pixel_b),.covered(cover_b));
`undef RENDER_PORTS
    always @(negedge clk)begin
        rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
        x=rng[9:0];y=rng[19:10];pixel_tick=rng[31:20];
    end
`define COMPAT_PORTS(V) \
    .clk(clk),.rst_n(rst_n),.sample_tick(sample),.pause(pause),.song_id(song), \
    .ui_start(start),.ui_toggle(toggle),.ui_restart(restart), \
    .roll_tick(V[77:66]),.roll_song(V[65:64]),.active(V[63]),.done(V[62]), \
    .step_index(V[61:56]),.total_steps(V[55:50]),.total_beats(V[49:44]), \
    .beat_progress(V[43:36]),.target_beats(V[35:34]),.beat_pulse(V[33]), \
    .expected_note(V[32:26]),.expected_valid(V[25]),.cue_mask(V[24:13]), \
    .next_mask(V[12:1]),.count_in(V[0])
    piano_roll_guide #(.BEAT_SAMPLES(67),.CUSTOM_SCORE_ENABLE(1)) dut(`COMPAT_PORTS(a),
        .custom_write_clk(clk),.custom_write_en(1'b0),.custom_write_addr(9'd0),
        .custom_write_data(32'd0),.custom_config(cfg));
    piano_roll_guide_baseline #(.BEAT_SAMPLES(67)) golden(`COMPAT_PORTS(b));
`undef COMPAT_PORTS
    integer checks=0,s,i;
    always @(posedge clk)begin
        #1;if(rst_n)begin
            checks=checks+1;
            if(a!==b)$fatal(1,"enabled built-in differs song=%0d a=%h b=%h",song,a,b);
            if({cover_a,pixel_a}!=={cover_b,pixel_b})$fatal(1,"enabled builtin renderer differs song=%0d xy=%0d,%0d",song,x,y);
        end
    end
    initial begin
        repeat(3)@(negedge clk);rst_n=1;
        for(s=0;s<3;s=s+1)begin
            @(negedge clk);song=s;start=1;
            @(negedge clk);start=0;sample=1;
            for(i=0;i<5000;i=i+1)begin
                @(negedge clk);cfg=32'hc51d0000+i*101;
                pause=(i%211<7);toggle=(i==100 || i==120);restart=(i==300);
            end
            @(negedge clk);sample=0;pause=0;toggle=0;restart=0;
            if(!a[62])$fatal(1,"built-in did not complete");
        end
        $display("CUSTOM_BUILTIN_COMPAT_PASS songs=3 frozen_baseline=1 guide_and_renderer=1 cycles=%0d",checks);
        $finish;
    end
endmodule
