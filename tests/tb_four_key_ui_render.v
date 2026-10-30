`timescale 1ns/1ps
// Real DUT RGB capture, continuous pixels, no DUT-internal oracle access.
// TWO registered stages: input accepted at edge N appears after edge N+1.
// Run from the project root so the original font ROM is loaded unchanged.
module tb_four_key_ui_render;
    reg clk=0, rst_n=0; always #5 clk=~clk;
    reg [9:0] x=0,y=0;
    reg de=0;
    reg [1:0] page=0;
    reg [1:0] strum_mode=0;
    reg [3:0] controls=0;
    reg test_active=0;
    reg signed [15:0] wave_current=0,wave_previous=0;
    wire [23:0] rgb;
`ifdef FOUR_KEY_PIANO
    hdmi_compact_dashboard #(.PIANO_ROLL_ENABLE(1)) dut(
        .piano_keys(32'h00280000),.piano_outside(1'b0),
        .roll_tick(12'd128),.roll_song(2'd0),.roll_active(1'b1),.roll_done(1'b0),
`else
    hdmi_compact_dashboard dut(
`endif
        .pixel_clk(clk),.rst_n(rst_n),.x(x),.y(y),.de(de),
        .keys(12'h005),.timbre(4'd0),.note(7'd60),.note_valid(1'b1),
        .frequency_bcd(16'h0262),.volume_percent(8'd73),.level_dbfs(-8'sd18),
        .peak_percent(8'd86),.voices(test_active ? 6'd32 : 6'd3),.flags(8'h24),
        .cue_mask(12'h001),.next_mask(12'h002),.wrong_mask(12'h004),
        .guide_step(6'd1),.guide_total(6'd42),.wave_current(wave_current),
        .wave_previous(wave_previous),.scope_gain(4'd0),.wave_valid(1'b1),
        .test_active(test_active),.test_requested(6'd32),
        .test_busy(32'hffffffff),.test_gate(32'hffffffff),
        .test_sweep(1'b1),.test_index(5'd31),.test_overrun(1'b0),
        .ui_page(page),.ui_cursor(2'd1),.ui_song(2'd0),.ui_controls(controls),
        .control_page(2'd2),.fx_mode(2'd1),.strum_mode(strum_mode),
        .knob_values(32'hc0806040),.red(rgb[23:16]),.green(rgb[15:8]),.blue(rgb[7:0]));

    integer errors=0,checks=0,blank_checks=0,reset_checks=0,stable_checks=0;
    integer scene=0,mask=0,mode=0,first_y=0,last_y=480,scan_y=525,fd,n,xx,yy,amp,count=0,read_count;
    integer vx,vy,vd,vp,vt,vc;
    reg [23:0] expected,previous_expected,stable_rgb;
    reg previous_visible=0,previous_valid=0;
    string ppm_path,probe_path;

    task fail;
        input [255:0] kind;
        input [23:0] want;
        begin
            errors=errors+1;
            if(errors<=12)$display("MISMATCH %0s input=(%0d,%0d) want=%06h rgb=%06h",kind,x,y,want,rgb);
        end
    endtask

    task reset_dut;
        begin
            @(negedge clk);rst_n=0;#1;
            reset_checks=reset_checks+1;
            if(rgb!==24'd0)fail("asynchronous_reset",0);
            repeat(2)@(negedge clk);
            rst_n=1;previous_valid=0;previous_visible=0;
        end
    endtask

    task probe_token;
        input integer tx,ty,td,tp,tt,tc;
        input [23:0] want;
        begin
            @(negedge clk);stable_rgb=rgb;
            x=tx;y=ty;de=td;page=tp;test_active=tt;controls=tc;
            #1;stable_checks=stable_checks+1;
            if(rgb!==stable_rgb)fail("changed_before_clock",stable_rgb);
            @(posedge clk);#1;
            checks=checks+1;
            if(previous_valid)begin
                if(rgb!==previous_expected)fail("two_stage_pipeline",previous_expected);
            end else if(rgb!==24'd0)fail("reset_first_stage",0);
            previous_expected=want;previous_valid=1;
        end
    endtask

    initial begin
        reset_dut;
        if($value$plusargs("PROBE=%s",probe_path))begin
            fd=$fopen(probe_path,"r");if(!fd)$fatal(1,"Cannot open probe vectors");
            while(!$feof(fd))begin
                read_count=$fscanf(fd,"%d %d %d %d %d %d %h\n",vx,vy,vd,vp,vt,vc,expected);
                if(read_count==7)begin
                    probe_token(vx,vy,vd,vp,vt,vc,expected);count=count+1;
                    if(count==257 || count==2051 || count==5003)begin
                        // Check the queued token before intentionally resetting the pipeline.
                        probe_token(0,0,0,0,0,0,0);reset_dut;
                    end
                end else if(!$feof(fd))$fatal(1,"Malformed probe vector");
            end
            $fclose(fd);probe_token(0,0,0,0,0,0,0);probe_token(0,0,0,0,0,0,0);
            $display("FOUR_KEY_PROBE checks=%0d stable=%0d resets=%0d errors=%0d",checks,stable_checks,reset_checks,errors);
        end else begin
            if(!$value$plusargs("PPM=%s",ppm_path))$fatal(1,"Missing PPM path");
            if(!$value$plusargs("SCENE=%d",scene))scene=0;
            if(!$value$plusargs("CONTROL=%d",mask))mask=0;
            if(!$value$plusargs("MODE=%d",mode))mode=0;
            if(mode<0 || mode>2)$fatal(1,"Invalid three-mode render stimulus");
            strum_mode=mode;
            if($test$plusargs("FOOTER_ONLY"))first_y=448;
            if($test$plusargs("HEADER_ONLY"))begin first_y=0;last_y=32;scan_y=32;end
            page=scene==4 ? 3 : scene;test_active=scene==4;controls=mask;
            fd=$fopen(ppm_path,"wb");if(!fd)$fatal(1,"Cannot open PPM");
            $fwrite(fd,"P6\n640 %0d\n255\n",last_y-first_y);
            // Raster includes 160 horizontal and 45 vertical blanking pixels/lines.
            // The final extra token drains the second registered stage.
            for(n=0;n<=800*(scan_y-first_y);n=n+1)begin
                @(negedge clk);
                xx=n%800;yy=first_y+n/800;x=xx;y=yy;de=xx<640 && yy<last_y;
                amp=(xx/2)%64;amp=amp<32 ? amp-16 : 48-amp;
                wave_current=amp*700;wave_previous=amp*700;
                @(posedge clk);#1;
                if(previous_valid)begin
                    if(previous_visible)begin
                        if((^rgb)===1'bx)fail("unknown_active_RGB",0);
                        $fwrite(fd,"%c%c%c",rgb[23:16],rgb[15:8],rgb[7:0]);count=count+1;
                    end else begin
                        blank_checks=blank_checks+1;
                        if(rgb!==24'd0)fail("blanking",0);
                    end
                end else if(rgb!==24'd0)fail("reset_first_stage",0);
                previous_visible=de;previous_valid=1;
            end
            $fclose(fd);
            if(count!=640*(last_y-first_y))$fatal(1,"Incomplete capture: %0d",count);
            $display("FOUR_KEY_CAPTURE scene=%0d mode=%0d controls=%04b pixels=%0d blanking=%0d errors=%0d",scene,strum_mode,controls,count,blank_checks,errors);
        end
        if(errors)$fatal(1,"Four-key rendering bench failed: %0d",errors);
        $display("FOUR_KEY_UI_RENDER_PASS");$finish;
    end
    initial begin #30000000;$fatal(1,"Render timeout");end
endmodule
