`timescale 1ns/1ps
// Real font + real two-stage renderer. Expected pixels come from the independent
// Python literal text oracle; this bench never reads DUT row IDs/character ROM.
module tb_v035_display_pixels;
    reg clk=0,rst_n=0;always #5 clk=~clk;
    reg [9:0] x=0,y=0;reg de=0;
    reg [1:0] page=3,mode=2,control_page=2;
    reg [3:0] controls=5;
    reg test_active=0,sweep=0,overrun=0;
    reg [5:0] requested=0,voices=3;reg [4:0] index=0;
    reg [31:0] busy=0,gate=0,adc=32'h7abc0123;
    reg [1:0] calibrated=1;
    reg [7:0] velocity=91,pressure0=73,pressure1=201;
    reg signed [8:0] bend=-137;
    reg [6:0] modulation=69;
    wire [23:0] rgb,legacy_rgb;
`define PIXEL_PORTS \
    .pixel_clk(clk),.rst_n(rst_n),.x(x),.y(y),.de(de), \
    .keys(12'h005),.timbre(4'd0),.note(7'd60),.note_valid(1'b1), \
    .frequency_bcd(16'h0262),.volume_percent(8'd73),.level_dbfs(-8'sd18), \
    .peak_percent(8'd86),.voices(voices),.flags(8'h24), \
    .cue_mask(12'h001),.next_mask(12'h002),.wrong_mask(12'h004), \
    .guide_step(6'd1),.guide_total(6'd42),.wave_current(16'sd0),.wave_previous(16'sd0), \
    .scope_gain(4'd0),.wave_valid(1'b1),.test_active(test_active),.test_requested(requested), \
    .test_busy(busy),.test_gate(gate),.test_sweep(sweep),.test_index(index),.test_overrun(overrun), \
    .ui_page(page),.ui_cursor(2'd1),.ui_song(2'd0),.ui_controls(controls), \
    .control_page(control_page),.fx_mode(2'd1),.strum_mode(mode),.knob_values(32'hc0806040), \
    .piano_keys(32'h00280000),.piano_outside(1'b0),.roll_tick(12'd128), \
    .roll_song(2'd0),.roll_active(1'b1),.roll_done(1'b0)
    hdmi_compact_dashboard #(.PIANO_ROLL_ENABLE(1),.EXPRESSION_UI_ENABLE(1)) dut(
        `PIXEL_PORTS,
        .expression_adc(adc),.expression_calibrated(calibrated),.midi_velocity(velocity),
        .midi_bend(bend),.midi_modulation(modulation),.pressure0(pressure0),.pressure1(pressure1),
        .red(rgb[23:16]),.green(rgb[15:8]),.blue(rgb[7:0]));
    // Deliberately leave every new input floating on the feature-disabled DUT.
    hdmi_compact_dashboard #(.PIANO_ROLL_ENABLE(1)) compatibility(
        `PIXEL_PORTS,.red(legacy_rgb[23:16]),.green(legacy_rgb[15:8]),.blue(legacy_rgb[7:0]));
`undef PIXEL_PORTS
    task select_case;
        input integer n;
        begin
            page=3;mode=2;control_page=2;controls=5;test_active=0;sweep=0;overrun=0;
            requested=0;voices=3;index=0;busy=0;gate=0;
            adc=32'h7abc0123;calibrated=1;velocity=91;bend=-137;modulation=69;pressure0=73;pressure1=201;
            case(n)
                1:begin adc=32'hffff8000;calibrated=2;velocity=0;bend=0;modulation=0;pressure0=0;pressure1=255;end
                2:begin adc=32'h00007fff;calibrated=3;velocity=127;bend=-256;modulation=127;pressure0=255;pressure1=0;end
                3:begin adc=32'hdeadbeef;calibrated=0;velocity=1;bend=255;modulation=1;pressure0=12;pressure1=234;end
                4,5,6,7,8,9:begin
                    test_active=1;
                    case(n)
                        4:requested=1;5:requested=4;6:requested=8;7:requested=16;default:requested=32;
                    endcase
                    gate=requested==32 ? 32'hffffffff : (32'd1<<requested)-1;
                    busy=n==4 ? 32'h80000001 : gate;
                    voices=n==4 ? 2 : requested;index=n==9 ? 31 : n-4;
                    sweep=n==9;overrun=n==9;
                end
                10:page=0;
                11:page=1;
                12:page=2;
                14:begin adc[15:0]=16'hfedc;pressure0=254;calibrated[0]=0;end
                15:begin adc[31:16]=16'hf00d;pressure1=7;calibrated[1]=1;end
                default:begin end
            endcase
        end
    endtask
    integer fd,nread,case_id=0,xx,yy,dd,cc,n,count=0,checks=0,compat_checks=0,blank_checks=0;
    string vectors,ppm;
    reg [23:0] expected,previous_expected;
    reg previous_valid=0,previous_visible=0,previous_compare=0;
    task token;
        input integer tx,ty,td,tc;
        input [23:0] want;
        reg [23:0] stable;
        begin
            @(negedge clk);stable=rgb;x=tx;y=ty;de=td;select_case(tc);#1;
            if(rgb!==stable)$fatal(1,"RGB changed without pixel clock");
            @(posedge clk);#1;
            if(previous_valid)begin
                checks=checks+1;
                if(rgb!==previous_expected)$fatal(1,"Literal pixel mismatch token%0d actual%06h expected%06h",checks,rgb,previous_expected);
                if(previous_compare)begin
                    compat_checks=compat_checks+1;
                    if(rgb!==legacy_rgb)$fatal(1,"Feature0/1 LIVE/LIBRARY pixels differ");
                end
            end else if(rgb!==0)$fatal(1,"First pipeline stage not blank");
            previous_expected=want;previous_valid=1;previous_compare=tc==10 || tc==11;
        end
    endtask
    initial begin
        repeat(3)@(negedge clk);rst_n=1;
        if($value$plusargs("VECTORS=%s",vectors))begin
            fd=$fopen(vectors,"r");if(!fd)$fatal(1,"Cannot open independent oracle vectors");
            while(!$feof(fd))begin
                nread=$fscanf(fd,"%d %d %d %d %h\n",xx,yy,dd,cc,expected);
                if(nread==5)token(xx,yy,dd,cc,expected);
                else if(!$feof(fd))$fatal(1,"Malformed pixel vectors");
            end
            $fclose(fd);token(0,0,0,0,0);token(0,0,0,0,0);
            $display("V035_DISPLAY_PIXELS_PASS literal_checks=%0d compatibility=%0d",checks,compat_checks);
        end else begin
            if(!$value$plusargs("PPM=%s",ppm))$fatal(1,"Missing capture PPM path");
            if(!$value$plusargs("SCENE=%d",case_id))case_id=0;
            select_case(case_id);
            fd=$fopen(ppm,"wb");if(!fd)$fatal(1,"Cannot open capture");
            $fwrite(fd,"P6\n640 480\n255\n");
            for(n=0;n<=800*525;n=n+1)begin
                @(negedge clk);xx=n%800;yy=n/800;x=xx;y=yy;de=xx<640 && yy<480;
                @(posedge clk);#1;
                if(previous_valid)begin
                    if(previous_visible)begin
                        if((^rgb)===1'bx)$fatal(1,"Unknown active RGB");
                        $fwrite(fd,"%c%c%c",rgb[23:16],rgb[15:8],rgb[7:0]);count=count+1;
                    end else begin blank_checks=blank_checks+1;if(rgb!==0)$fatal(1,"Raster blanking");end
                end
                previous_visible=de;previous_valid=1;
            end
            $fclose(fd);if(count!=640*480)$fatal(1,"Incomplete frame");
            $display("V035_DISPLAY_CAPTURE_PASS scene=%0d pixels=%0d blanking=%0d",case_id,count,blank_checks);
        end
        $finish;
    end
    initial begin #30000000;$fatal(1,"V035 pixel timeout");end
endmodule
