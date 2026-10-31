`timescale 1ns/1ps
// Public-port scenarios and independent literal-text pixel oracle. No DUT ROM
// or row-ID inspection. Two-cycle RGB and blanking, with a frozen feature0 miter.
module tb_display_pixels;
    reg clk=0,rst_n=0;always #5 clk=~clk;
    reg [9:0] x=0,y=0;reg de=0;
    reg [1:0] page,mode,song,strum,cursor;
    reg waiting,active,done,owned;
    reg [13:0] scenes[0:63];
    wire [23:0] rgb,old_rgb,golden_rgb;
`define PORTS \
    .pixel_clk(clk),.rst_n(rst_n),.x(x),.y(y),.de(de), \
    .keys(12'd0),.timbre(4'd0),.note(7'd60),.note_valid(1'b1), \
    .frequency_bcd(16'h0262),.volume_percent(8'd73),.level_dbfs(-8'sd18), \
    .peak_percent(8'd86),.voices(6'd3),.flags(8'h24), \
    .cue_mask(12'd1),.next_mask(12'd2),.wrong_mask(12'd0), \
    .guide_step(6'd1),.guide_total(6'd42),.wave_current(16'd0),.wave_previous(16'd0), \
    .scope_gain(4'd0),.wave_valid(1'b1),.test_active(owned),.test_requested(6'd32), \
    .test_busy(32'h80000001),.test_gate(32'h00000001),.test_sweep(1'b1), \
    .test_index(5'd31),.test_overrun(1'b0),.ui_page(page),.ui_cursor(cursor), \
    .ui_song(song),.ui_controls(4'd5),.control_page(2'd2),.fx_mode(2'd1), \
    .strum_mode(strum),.knob_values(32'hc0806040),.piano_keys(32'h00280000), \
    .piano_outside(1'b0),.roll_tick(12'd128),.roll_song(song), \
    .roll_active(active),.roll_done(done),.expression_adc(32'h7abc0123), \
    .expression_calibrated(2'b01),.midi_velocity(8'd91),.midi_bend(-9'sd137), \
    .midi_modulation(7'd69),.pressure0(8'd73),.pressure1(8'd201), \
    .visual_fft_level(8'd0),.visual_xy_dot(1'b0),.visual_fft_valid(1'b0),.visual_xy_valid(1'b0), \
    .custom_write_clk(clk),.custom_write_en(1'b0),.custom_write_addr(9'd0), \
    .custom_write_data(32'd0),.custom_config(32'd0),.frame_tick(1'b0),.roll_custom_bank(1'b0)
    hdmi_compact_dashboard #(.PIANO_ROLL_ENABLE(1),.EXPRESSION_UI_ENABLE(1),
        .VISUALIZATION_ENABLE(1),.CUSTOM_SCORE_ENABLE(1),.SONG_LIBRARY_ENABLE(1)) dut(
        `PORTS,.guide_mode(mode),.practice_wait(waiting),.red(rgb[23:16]),.green(rgb[15:8]),.blue(rgb[7:0]));
    // Leave new inputs floating on disabled feature, like historical callers.
    hdmi_compact_dashboard #(.PIANO_ROLL_ENABLE(1),.EXPRESSION_UI_ENABLE(1),
        .VISUALIZATION_ENABLE(1),.CUSTOM_SCORE_ENABLE(1)) disabled(
        `PORTS,.red(old_rgb[23:16]),.green(old_rgb[15:8]),.blue(old_rgb[7:0]));
    hdmi_compact_dashboard_golden #(.PIANO_ROLL_ENABLE(1),.EXPRESSION_UI_ENABLE(1),
        .VISUALIZATION_ENABLE(1),.CUSTOM_SCORE_ENABLE(1)) golden(
        `PORTS,.red(golden_rgb[23:16]),.green(golden_rgb[15:8]),.blue(golden_rgb[7:0]));
`undef PORTS
    task select_scene;
        input integer s;
        begin {page,mode,waiting,active,done,owned,song,strum,cursor}=scenes[s];end
    endtask
    string scenario_file,vectors,ppm;
    integer fd,nread,xx,yy,dd,ss,n,scene=0,scene_count=0,checks=0,blanks=0,pixels=0;
    reg [23:0] expected,previous_expected,stable;
    reg have_previous=0,was_visible=0;
    integer prev_x,prev_y,prev_scene;
    task token;
        input integer tx,ty,td,ts;
        input [23:0] want;
        begin
            @(negedge clk);stable=rgb;x=tx;y=ty;de=td;select_scene(ts);#1;
            if(rgb!==stable)$fatal(1,"Unclocked RGB change");
            @(posedge clk);#1;
            if(have_previous)begin
                if(rgb!==previous_expected)$fatal(1,"Literal mismatch scene%0d (%0d,%0d) got%06h want%06h",
                    prev_scene,prev_x,prev_y,rgb,previous_expected);
                if(old_rgb!==golden_rgb)$fatal(1,"Feature0 changed at (%0d,%0d)",prev_x,prev_y);
                checks=checks+1;
            end
            previous_expected=want;have_previous=1;prev_x=tx;prev_y=ty;prev_scene=ts;
        end
    endtask
    initial begin
        if(!$value$plusargs("SCENARIOS=%s",scenario_file) || !$value$plusargs("COUNT=%d",scene_count))
            $fatal(1,"Missing scenarios");
        $readmemh(scenario_file,scenes,0,scene_count-1);select_scene(0);
        repeat(3)@(negedge clk);rst_n=1;
        if($value$plusargs("VECTORS=%s",vectors))begin
            fd=$fopen(vectors,"r");if(!fd)$fatal(1,"Cannot open vectors");
            while(!$feof(fd))begin
                nread=$fscanf(fd,"%d %d %d %d %h\n",xx,yy,dd,ss,expected);
                if(nread==5)token(xx,yy,dd,ss,expected);
                else if(!$feof(fd))$fatal(1,"Bad vector");
            end
            $fclose(fd);token(0,0,0,0,0);token(0,0,0,0,0);
            $display("V045_PIXELS_PASS literal=%0d feature0_miter=%0d",checks,checks);
        end else begin
            if(!$value$plusargs("PPM=%s",ppm) || !$value$plusargs("SCENE=%d",scene))$fatal(1,"Missing capture args");
            select_scene(scene);fd=$fopen(ppm,"wb");if(!fd)$fatal(1,"Cannot open capture");
            $fwrite(fd,"P6\n640 480\n255\n");
            for(n=0;n<=800*525;n=n+1)begin
                @(negedge clk);xx=n%800;yy=n/800;x=xx;y=yy;de=xx<640 && yy<480;
                @(posedge clk);#1;
                if(have_previous)begin
                    if(old_rgb!==golden_rgb)$fatal(1,"Feature0 frame differs scene%0d pixel%0d",scene,n);
                    if(was_visible)begin
                        if((^rgb)===1'bx)$fatal(1,"Unknown visible pixel");
                        $fwrite(fd,"%c%c%c",rgb[23:16],rgb[15:8],rgb[7:0]);pixels=pixels+1;
                    end else begin if(rgb!==0)$fatal(1,"Blanking");blanks=blanks+1;end
                end
                was_visible=de;have_previous=1;
            end
            $fclose(fd);if(pixels!=307200)$fatal(1,"Incomplete raster");
            $display("V045_CAPTURE_PASS scene=%0d pixels=%0d blanking=%0d feature0_miter=420000",scene,pixels,blanks);
        end
        $finish;
    end
    initial begin #100000000;$fatal(1,"Pixel timeout");end
endmodule
