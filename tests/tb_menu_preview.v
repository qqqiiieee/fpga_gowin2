`timescale 1ns/1ps
// Expected vectors/frames are built from menu_layout.json by menu_tests.py,
// never from DUT coordinates, labels, font muxes or internal functions.
module tb_menu_preview;
    reg pixel_clk=0,rst_n=0; always #5 pixel_clk=~pixel_clk;
    reg [9:0] x=0,y=0; reg de=1;
    reg [15:0] keys16=0;
    reg [1:0] page=0,cursor=0,song=0;
    reg [7:0] flags=0;
    reg guide_active=1,test_active=0;
    reg signed [15:0] wave_current=0,wave_previous=0;
    wire [23:0] rgb,legacy_rgb;
    hdmi_instrument_dashboard #(.UI_ENABLE(1)) dut(
        .pixel_clk(pixel_clk),.rst_n(rst_n),.x(x),.y(y),.de(de),
        .keys(keys16[11:0]),.ui_page(page),.ui_cursor(cursor),.ui_song(song),.ui_controls(keys16[15:12]),
        .timbre(4'd0),.note(7'd60),.note_valid(1'b1),.frequency_bcd(16'h0262),
        .volume_percent(8'd73),.level_dbfs(-8'sd18),.peak_percent(8'd86),.pitch(9'sd0),
        .voices(test_active ? 6'd32 : 6'd1),.pressure0(8'd88),.pressure1(8'd128),.flags(flags),
        .guide_active(guide_active),.guide_done(1'b0),.cue_mask(12'd1),.next_mask(12'd2),.wrong_mask(12'd4),
        .guide_step(6'd1),.guide_total(6'd42),.beat_progress(8'd73),.target_beats(2'd1),
        .wave_current(wave_current),.wave_previous(wave_previous),.scope_gain(4'd0),.wave_valid(1'b1),
        .test_active(test_active),.test_requested(6'd32),.test_busy(32'hffffffff),.test_gate(32'hffffffff),
        .test_sweep(1'b0),.test_index(5'd0),.test_overrun(1'b0),
        .red(rgb[23:16]),.green(rgb[15:8]),.blue(rgb[7:0]));
    // Deliberately omit UI_ENABLE: verifies the frozen default-zero path.
    hdmi_instrument_dashboard legacy(
        .pixel_clk(pixel_clk),.rst_n(rst_n),.x(x),.y(y),.de(de),
        .keys(keys16[11:0]),.ui_page(page),.ui_cursor(cursor),.ui_song(song),.ui_controls(keys16[15:12]),
        .timbre(4'd0),.note(7'd60),.note_valid(1'b1),.frequency_bcd(16'h0262),
        .volume_percent(8'd73),.level_dbfs(-8'sd18),.peak_percent(8'd86),.pitch(9'sd0),
        .voices(test_active ? 6'd32 : 6'd1),.pressure0(8'd88),.pressure1(8'd128),.flags(flags),
        .guide_active(guide_active),.guide_done(1'b0),.cue_mask(12'd1),.next_mask(12'd2),.wrong_mask(12'd4),
        .guide_step(6'd1),.guide_total(6'd42),.beat_progress(8'd73),.target_beats(2'd1),
        .wave_current(wave_current),.wave_previous(wave_previous),.scope_gain(4'd0),.wave_valid(1'b1),
        .test_active(test_active),.test_requested(6'd32),.test_busy(32'hffffffff),.test_gate(32'hffffffff),
        .test_sweep(1'b0),.test_index(5'd0),.test_overrun(1'b0),
        .red(legacy_rgb[23:16]),.green(legacy_rgb[15:8]),.blue(legacy_rgb[7:0]));
    reg [12:0] probe_address=0;
    wire [7:0] probe_bits;
    reg [7:0] previous_probe;
    reg [7:0] reference_font[0:8191];
    hdmi_ui_font font_probe(pixel_clk,probe_address,probe_bits);
    reg [23:0] expected_frame[0:307199];
    integer checks=0,fd,n,px,py,i,j,scene,output_file;
    integer vp,vc,vs,vk,vf,vg,vd,vx,vy;
    reg [23:0] expected;
    reg [2047:0] output_path,expected_path;
    task sample;
        input integer xx,yy;
        begin
            @(negedge pixel_clk);x=xx;y=yy;
            @(posedge pixel_clk);#1;checks=checks+1;
            if((^rgb)===1'bx)$fatal(1,"Unknown RGB page=%0d x=%0d y=%0d",page,xx,yy);
        end
    endtask
    function integer wave_sample;
        input integer address;
        integer t;
        begin t=address%64;wave_sample=(t<32 ? t-16 : 48-t)*700;end
    endfunction
    task capture;
        input integer which;
        begin
            page=0;cursor=0;song=0;keys16=0;flags=0;guide_active=1;test_active=0;de=1;
            case(which)
                1:begin page=1;cursor=1;song=1;guide_active=0;end
                2:begin page=2;cursor=2;keys16=16'h0140;guide_active=0;end
                3:begin page=3;keys16=16'h0340;guide_active=0;end
                4:begin page=3;cursor=2;song=2;test_active=1;guide_active=0;end
            endcase
            case(which)
                0:output_path="LIVE_song0.ppm";
                1:begin output_path="LIBRARY_song1_cursor1.ppm";expected_path="LIBRARY_song1_cursor1.hex";end
                2:begin output_path="HELP_keys_cursor2.ppm";expected_path="HELP_keys_cursor2.hex";end
                3:begin output_path="DIAG_S9_S10_S7.ppm";expected_path="DIAG_S9_S10_S7.hex";end
                4:output_path="TEST32_priority.ppm";
            endcase
            if(which>=1 && which<=3)$readmemh(expected_path,expected_frame);
            output_file=$fopen(output_path,"w");if(!output_file)$fatal(1,"Cannot open PPM");
            $fwrite(output_file,"P3\n# instrument menu renderer RTL\n640 480\n255\n");
            for(py=0;py<480;py=py+1)for(px=0;px<640;px=px+1)begin
                i=(px>=32 && px<544) ? (px-32)/2 : 0;
                wave_current=wave_sample(i);wave_previous=wave_sample(i==0 ? 0 : i-1);
                sample(px,py);
                if(which>=1 && which<=3 && rgb!==expected_frame[py*640+px])
                    $fatal(1,"Menu frame scene=%0d (%0d,%0d) expected=%06h actual=%06h",which,px,py,expected_frame[py*640+px],rgb);
                if(which==0 && py<448 && rgb!==legacy_rgb)
                    $fatal(1,"LIVE song0 legacy body differs (%0d,%0d)",px,py);
                if(which==4 && rgb!==legacy_rgb)$fatal(1,"TEST32 priority differs (%0d,%0d)",px,py);
                $fwrite(output_file,"%0d %0d %0d\n",rgb[23:16],rgb[15:8],rgb[7:0]);
            end
            $fclose(output_file);
            $display("MENU_RTL_FRAME_PASS scene=%0d path=%0s",which,output_path);
        end
    endtask
    initial begin
        $readmemh("src/ui_font.hex",reference_font);
        repeat(2)@(negedge pixel_clk);rst_n=1;
        // All addresses, alternating low/high codes, include 510/511 every row.
        for(j=0;j<8192;j=j+1)begin
            @(negedge pixel_clk);previous_probe=probe_bits;probe_address=(j%2) ? 8191-j/2 : j/2;
            #1;if(j>0 && probe_bits!==previous_probe)$fatal(1,"Font changed before next rising edge");
            @(posedge pixel_clk);#1;
            if(probe_bits!==reference_font[probe_address])$fatal(1,"Font one-cycle address=%0d",probe_address);
        end
        $display("MENU_FONT_PASS addresses=8192 codes510_511=32_rows");
        // Capture first: deliver actual preview files before the extended probes.
        if(!$test$plusargs("CHECKS_ONLY"))for(scene=0;scene<5;scene=scene+1)capture(scene);
        if($test$plusargs("FRAMES_ONLY"))begin
            $display("MENU_PREVIEW_FRAMES_PASS five_RTL_frames checks=%0d",checks);$finish;
        end
        wave_current=0;wave_previous=0;
        fd=$fopen("menu_vectors.txt","r");if(!fd)$fatal(1,"Missing independent vectors");
        while(!$feof(fd))begin
            n=$fscanf(fd,"%d %d %d %h %h %d %d %d %d %h\n",vp,vc,vs,vk,vf,vg,vd,vx,vy,expected);
            if(n==10)begin
                page=vp;cursor=vc;song=vs;keys16=vk;flags=vf;guide_active=vg;de=vd;test_active=0;
                sample(vx,vy);
                if(rgb!==expected)$fatal(1,"Independent vector page=%0d cursor=%0d song=%0d keys=%04h flags=%02h (%0d,%0d) expected=%06h actual=%06h",page,cursor,song,keys16,flags,vx,vy,expected,rgb);
            end else if(n!=-1)$fatal(1,"Bad vector record fields=%0d",n);
        end
        $fclose(fd);de=1;test_active=1;
        // Test ownership overrides every page/cursor/song, including font rows.
        for(vp=0;vp<4;vp=vp+1)begin
            page=vp;cursor=2;song=2;keys16=16'hf340;
            for(py=0;py<480;py=py+1)for(px=0;px<640;px=px+1)begin
                sample(px,py);if(rgb!==legacy_rgb)$fatal(1,"Test precedence page=%0d (%0d,%0d)",page,px,py);
            end
        end
        rst_n=0;#1;if(rgb!==0)$fatal(1,"Renderer reset not black");
        @(negedge pixel_clk);rst_n=1;de=0;sample(32,16);if(rgb!==0)$fatal(1,"Blanking not black");
        $display("MENU_PREVIEW_TEST_PASS checks=%0d five_RTL_frames full_menu_oracle test_all_pages",checks);$finish;
    end
    initial begin #150000000;$fatal(1,"Menu preview timeout");end
endmodule
