`timescale 1ns/1ps
// Pixel oracle uses geometric arithmetic independently of the DUT x-ROM.
// Score expectations below are event anchors, not a duplicate song table.
module tb_piano_roll_pixels;
    reg clk=0,rst_n=0;always #5 clk=~clk;
    reg [9:0] x=0,y=0;reg de=1;
    reg [31:0] held=0;reg outside=0,active=0,done=0;
    reg [11:0] tick=0;reg [1:0] song=0,page=0;
    reg test_active=0;reg [6:0] note=61;reg note_valid=1;
    reg [11:0] pads=0;reg [31:0] busy=0;
    reg signed [15:0] wave0=0,wave1=0;
    wire [23:0] rgb,old_rgb;
`define PIXEL_PORTS \
    .pixel_clk(clk),.rst_n(rst_n),.x(x),.y(y),.de(de),.keys(pads), \
    .timbre(4'd0),.note(note),.note_valid(note_valid),.frequency_bcd(16'h0277), \
    .volume_percent(8'd73),.level_dbfs(-8'sd18),.peak_percent(8'd86), \
    .voices(6'd3),.flags(8'h24),.cue_mask(12'd1),.next_mask(12'd2),.wrong_mask(12'd4), \
    .guide_step(6'd1),.guide_total(6'd42),.wave_current(wave1),.wave_previous(wave0), \
    .scope_gain(4'd0),.wave_valid(1'b1),.test_active(test_active),.test_requested(6'd32), \
    .test_busy(busy),.test_gate(32'hffffffff),.test_sweep(1'b0),.test_index(5'd0),.test_overrun(1'b0), \
    .ui_page(page),.ui_cursor(2'd1),.ui_song(song),.ui_controls(4'd0), \
    .control_page(2'd2),.fx_mode(2'd1),.strum_mode(1'b0),.knob_values(32'hc0806040), \
    .piano_keys(held),.piano_outside(outside),.roll_tick(tick),.roll_song(song), \
    .roll_active(active),.roll_done(done)
    hdmi_compact_dashboard #(.PIANO_ROLL_ENABLE(1)) dut(`PIXEL_PORTS,
        .red(rgb[23:16]),.green(rgb[15:8]),.blue(rgb[7:0]));
    hdmi_compact_dashboard legacy(`PIXEL_PORTS,
        .red(old_rgb[23:16]),.green(old_rgb[15:8]),.blue(old_rgb[7:0]));
`undef PIXEL_PORTS
    localparam [23:0] BG=24'h0b101c,PANEL=24'h172338,GRID=24'h22324a,
        BORDER=24'h34465f,WHITE=24'he2e8f0,BLACK=24'h080d16,
        CYAN=24'h51d6e8,GREEN=24'h21c6a8,AMBER=24'hf4bb4f,ALERT=24'hff5964;
    integer checks=0,px,py,i,j,octave,w,scene,fd,address;
    reg [2047:0] ppm_path;
    reg [7:0] font[0:8191];
    reg [23:0] expected;
    task sample;
        input integer xx,yy;
        begin
            @(negedge clk);x=xx;y=yy;
            repeat(2)begin @(posedge clk);#1;end
            checks=checks+1;
            if((^rgb)===1'bx)$fatal(1,"Unknown pixel %0d,%0d",xx,yy);
        end
    endtask
    task expect_pixel;
        input integer xx,yy;input [23:0] colour;
        begin
            sample(xx,yy);
            if(rgb!==colour)$fatal(1,"Pixel(%0d,%0d) tick%0d held%08h expected%06h actual%06h",xx,yy,tick,held,colour,rgb);
        end
    endtask
    function integer white_pc;
        input integer white_index;
        begin
            case(white_index%7)
                0:white_pc=0;1:white_pc=2;2:white_pc=4;3:white_pc=5;
                4:white_pc=7;5:white_pc=9;default:white_pc=11;
            endcase
            white_pc=white_pc+12*(white_index/7);
        end
    endfunction
    function [23:0] keyboard_colour;
        input integer xx,yy;
        integer n,black_n,boundary,keynum,wn;
        reg sharp,pressed,cue;
        begin
            wn=(xx-35)/30;keynum=white_pc(wn);sharp=0;
            // Find only chromatic black boundaries, independently using pitch
            // class of the left white key (E/B never have a following sharp).
            for(n=0;n<18;n=n+1)begin
                boundary=65+30*n;black_n=white_pc(n);
                if(yy<370 && black_n%12!=4 && black_n%12!=11 &&
                    xx>=boundary-9 && xx<boundary+9)begin
                    keynum=black_n+1;sharp=1;
                end
            end
            pressed=held[keynum];cue=active && !done && tick==128 && keynum==12;
            keyboard_colour=sharp ? BLACK : WHITE;
            if(!sharp && (xx-35)%30==0)keyboard_colour=BORDER;
            if(cue)keyboard_colour=AMBER;
            if(pressed)keyboard_colour=(active && !done && tick==128) ? (cue ? GREEN : ALERT) : CYAN;
        end
    endfunction
    task check_name;
        input integer midi;input [31:0] text;
        integer xx,yy,cc;
        reg [7:0] ch;
        begin
            note=midi;
            for(yy=0;yy<16;yy=yy+1)for(xx=0;xx<32;xx=xx+1)begin
                cc=xx/8;ch=text >> (24-8*cc);
                expected=font[ch*16+yy][7-(xx%8)] ? WHITE : BG;
                expect_pixel(360+xx,48+yy,expected);
            end
        end
    endtask
    task check_c_label;
        input integer start_x;input [7:0] digit;
        integer xx,yy;reg [7:0] ch;
        begin
            for(yy=0;yy<16;yy=yy+1)for(xx=0;xx<16;xx=xx+1)begin
                ch=xx<8 ? "C" : digit;
                expected=font[ch*16+yy][7-(xx%8)] ? PANEL : WHITE;
                expect_pixel(start_x+xx,380+yy,expected);
            end
        end
    endtask
    // Continuous one-pixel-per-clock capture, including the final pipeline
    // flush. PPM bytes come directly from real RTL RGB, never an image oracle.
    task capture;
        integer n,xx,yy,amp;
        begin
            fd=$fopen(ppm_path,"w");if(!fd)$fatal(1,"Cannot open PPM");
            $fwrite(fd,"P3\n# real compact RTL pixels; synthetic physical-held and PCM inputs\n640 480\n255\n");
            for(n=0;n<=307200;n=n+1)begin
                @(negedge clk);xx=n%640;yy=n/640;x=xx;y=yy;de=n<307200;
                amp=((xx/2)%64);amp=amp<32 ? amp-16 : 48-amp;
                wave0=amp*700;wave1=amp*700;
                @(posedge clk);#1;
                if(n>0)begin
                    if((^rgb)===1'bx)$fatal(1,"Unknown frame pixel %0d",n-1);
                    $fwrite(fd,"%0d %0d %0d\n",rgb[23:16],rgb[15:8],rgb[7:0]);
                    // Test page, library and help must retain exact pixels.
                    if((test_active || page==1 || page==2) && rgb!==old_rgb)
                        $fatal(1,"Retained page differs at pixel%0d",n-1);
                end
            end
            $fclose(fd);de=1;
        end
    endtask
    initial begin
        $readmemh("src/ui_font.hex",font);
        repeat(3)@(negedge clk);rst_n=1;
        if(!$test$plusargs("CAPTURE_ONLY"))begin
        // Full keyboard width, both black/white tiers; every held bit, chords,
        // boundaries and a cue/incorrect held key with identical sound inputs.
        for(i=0;i<35;i=i+1)begin
            if(i<32)held=32'd1<<i;
            else if(i==32)held=32'hffffffff;
            else if(i==33)held=32'ha55aa55a;
            else held=0;
            active=i==34;tick=128;
            for(px=35;px<605;px=px+1)begin
                expect_pixel(px,350,keyboard_colour(px,350));
                expect_pixel(px,375,keyboard_colour(px,375));
            end
        end
        // Physical release must clear illumination even while touch/voice
        // telemetry remains asserted. No coupling to the twelve pad bits.
        active=0;held=0;pads=12'hfff;busy=32'hffffffff;
        expect_pixel(275,350,BLACK);expect_pixel(260,375,WHITE);
        held=32'h00001000;expect_pixel(260,375,CYAN);
        held=0;expect_pixel(260,375,WHITE);
        outside=1;expect_pixel(34,350,ALERT);expect_pixel(605,350,ALERT);
        expect_pixel(275,350,BLACK);outside=0;
        expect_pixel(34,143,BORDER);expect_pixel(605,400,BORDER);
        expect_pixel(33,200,BG);expect_pixel(606,200,BG);
        expect_pixel(34,401,BG);
        // First C4 starts at tick128. Its lower edge moves DOWN16px when
        // current tick advances16. Natural C4 centre260, sharp C#4 centre275.
        active=1;tick=0;
        expect_pixel(260,190,CYAN);expect_pixel(260,191,PANEL);
        expect_pixel(260,192,GRID);expect_pixel(253,190,PANEL);
        expect_pixel(254,190,CYAN);expect_pixel(265,190,CYAN);
        expect_pixel(266,190,PANEL);expect_pixel(275,190,PANEL);
        tick=16;expect_pixel(260,206,CYAN);expect_pixel(260,207,PANEL);
        active=0;expect_pixel(260,206,CYAN);expect_pixel(260,207,PANEL);
        held=32'h00002000;expect_pixel(275,350,CYAN);held=0;active=1;
        // Fixed songs contain natural notes; inject ONLY the helper's output
        // pitch to exercise the renderer's sharp bar lane without a new table.
        tick=0;force dut.piano_panel.u_piano.score_note=7'd61;
        expect_pixel(275,190,CYAN);expect_pixel(260,190,PANEL);
        expect_pixel(269,190,CYAN);expect_pixel(280,190,CYAN);
        expect_pixel(268,190,PANEL);expect_pixel(281,190,PANEL);
        release dut.piano_panel.u_piano.score_note;
        // Adjacent repeated C4s have their own onset gap, not merged.
        tick=64;expect_pixel(260,191,PANEL);expect_pixel(260,192,GRID);
        expect_pixel(260,193,CYAN);expect_pixel(260,190,CYAN);
        // G4 at beats8/9 is TWO beats: no separator at continuation beat9.
        tick=448;expect_pixel(380,256,GRID);expect_pixel(380,254,CYAN);
        expect_pixel(380,192,CYAN);expect_pixel(380,191,CYAN);
        // Late future tick must not wrap to the beginning of the score.
        tick=4090;expect_pixel(260,200,PANEL);
        tick=128;held=32'h00003000;
        expect_pixel(260,375,GREEN);expect_pixel(275,350,ALERT);
        done=1;expect_pixel(260,321,GREEN);expect_pixel(260,375,CYAN);
        active=0;done=0;held=0;
        check_c_label(44,"3");check_c_label(254,"4");check_c_label(464,"5");
        check_name(60,"C4  ");check_name(61,"C#4 ");check_name(0,"C-1 ");
        check_name(1,"C#-1");check_name(79,"G5  ");check_name(127,"G9  ");
        // Diagnostic PCM scope remains live; 32-oscillator page has priority.
        page=3;expect_pixel(100,212,CYAN);expect_pixel(100,200,PANEL);
        for(py=281;py<288;py=py+1)for(px=32;px<576;px=px+1)expect_pixel(px,py,BG);
        test_active=1;expect_pixel(100,212,CYAN);
        page=0;test_active=0;
        de=0;expect_pixel(260,375,0);de=1;
        expect_pixel(640,375,0);expect_pixel(260,480,0);expect_pixel(1023,1023,0);
        rst_n=0;#1;if(rgb!==0)$fatal(1,"Async reset did not blank");
        @(negedge clk);rst_n=1;
        end
        scene=0;if($value$plusargs("SCENE=%d",scene))begin end
        if($value$plusargs("PPM=%s",ppm_path))begin
            page=0;test_active=0;note=61;tick=176;active=1;held=32'h00003000;
            case(scene)
                1:begin tick=192;held=32'h00001000;end
                2:begin active=0;held=32'h82403001;outside=1;end
                3:begin page=3;active=0;end
                4:begin test_active=1;busy=32'hffffffff;end
                5:begin page=1;end
                6:begin page=2;end
            endcase
            capture;
        end
        if($test$plusargs("CAPTURE_ONLY"))$display("PIANO_ROLL_PREVIEW_PASS scene=%0d pixels=307200 pipeline2",scene);
        else $display("PIANO_ROLL_PIXELS_PASS checks=%0d 32heldbits chords sharps outside names boundary countin downscroll continuation reset blanking",checks);
        $finish;
    end
    initial begin #30000000;$fatal(1,"Pixel timeout");end
endmodule
