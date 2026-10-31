`timescale 1ns/1ps
// Adapted from V035: real font/renderer, independent literal pixel vectors.
// Scenario memory contains only public input-port stimuli. Never inspect DUT
// row IDs, character memory, generated text constants, or font addresses.
module tb_v037_display_pixels #(parameter VISUALIZATION_ENABLE=1);
    reg clk=0,rst_n=0;always #5 clk=~clk;
    reg [9:0] x=0,y=0;reg de=0;
    reg [1:0] page,mode,control_page;
    reg [3:0] controls,timbre;
    reg test_active,sweep,overrun,roll_active,roll_done,note_valid;
    reg [5:0] requested,voices;reg [4:0] index;
    reg [31:0] busy,gate,adc,knobs;
    reg [1:0] calibrated,song,cursor;
    reg [7:0] velocity,pressure0,pressure1,volume,peak,flags;
    reg signed [8:0] bend;reg signed [7:0] level_dbfs;
    reg [6:0] modulation,note;reg [15:0] frequency_bcd;
    reg fft_valid,xy_valid;
    reg [7:0] fft_memory[0:255];reg xy_memory[0:16383];
    reg [7:0] fft_level=0,legacy_fft_level=0;
    reg xy_dot=0,legacy_xy_dot=0;
    wire [7:0] fft_addr,legacy_fft_addr;
    wire [13:0] xy_addr,legacy_xy_addr;
    string fft_file,xy_file;
    // Model the documented one-clock external RAM read through public ports.
    // Fixture data comes from known independent source voices/PCM, never DUT RAM.
    always @(posedge clk)begin
        fft_level<=fft_memory[fft_addr];xy_dot<=xy_memory[xy_addr];
        legacy_fft_level<=fft_memory[legacy_fft_addr];legacy_xy_dot<=xy_memory[legacy_xy_addr];
    end
    localparam SCENARIO_BITS=268;
    reg [SCENARIO_BITS-1:0] scenarios[0:127];
    integer case_count=0,selected_case=-1;
    string stimuli;
    wire [23:0] rgb,legacy_rgb;
`define V037_PIXEL_PORTS \
    .pixel_clk(clk),.rst_n(rst_n),.x(x),.y(y),.de(de), \
    .keys(12'h005),.timbre(timbre),.note(note),.note_valid(note_valid), \
    .frequency_bcd(frequency_bcd),.volume_percent(volume),.level_dbfs(level_dbfs), \
    .peak_percent(peak),.voices(voices),.flags(flags), \
    .cue_mask(12'h001),.next_mask(12'h002),.wrong_mask(12'h004), \
    .guide_step(6'd1),.guide_total(6'd42),.wave_current(16'sd0),.wave_previous(16'sd0), \
    .scope_gain(4'd0),.wave_valid(1'b1),.test_active(test_active),.test_requested(requested), \
    .test_busy(busy),.test_gate(gate),.test_sweep(sweep),.test_index(index),.test_overrun(overrun), \
    .ui_page(page),.ui_cursor(cursor),.ui_song(song),.ui_controls(controls), \
    .control_page(control_page),.fx_mode(2'd1),.strum_mode(mode),.knob_values(knobs), \
    .piano_keys(32'h00280000),.piano_outside(1'b0),.roll_tick(12'd128), \
    .roll_song(song),.roll_active(roll_active),.roll_done(roll_done)
    hdmi_compact_dashboard #(.PIANO_ROLL_ENABLE(1),.EXPRESSION_UI_ENABLE(1),
                             .VISUALIZATION_ENABLE(VISUALIZATION_ENABLE)) dut(
        `V037_PIXEL_PORTS,
        .expression_adc(adc),.expression_calibrated(calibrated),.midi_velocity(velocity),
        .midi_bend(bend),.midi_modulation(modulation),.pressure0(pressure0),.pressure1(pressure1),
        .visual_fft_level(fft_level),.visual_xy_dot(xy_dot),
        .visual_fft_valid(fft_valid),.visual_xy_valid(xy_valid),
        .visual_fft_addr(fft_addr),.visual_xy_addr(xy_addr),
        .red(rgb[23:16]),.green(rgb[15:8]),.blue(rgb[7:0]));
    // Leave new inputs floating on feature0: LIVE/LIBRARY must still agree.
    hdmi_compact_dashboard #(.PIANO_ROLL_ENABLE(1),.VISUALIZATION_ENABLE(VISUALIZATION_ENABLE)) compatibility(
        `V037_PIXEL_PORTS,.visual_fft_level(legacy_fft_level),.visual_xy_dot(legacy_xy_dot),
        .visual_fft_valid(fft_valid),.visual_xy_valid(xy_valid),
        .visual_fft_addr(legacy_fft_addr),.visual_xy_addr(legacy_xy_addr),
        .red(legacy_rgb[23:16]),.green(legacy_rgb[15:8]),.blue(legacy_rgb[7:0]));
`undef V037_PIXEL_PORTS
    task select_case;
        input integer n;
        begin
            if(n<0 || n>=case_count)$fatal(1,"Unknown scenario %0d",n);
            // Consecutive pixels retain the same public input frame. Avoid
            // re-scattering 268 identical bits on every pixel in Icarus;
            // randomized vectors still switch scenarios on every token.
            if(n!=selected_case)begin
                {page,mode,control_page,controls,test_active,sweep,overrun,requested,voices,index,
                 busy,gate,adc,calibrated,velocity,bend,modulation,pressure0,pressure1,timbre,
                 roll_active,roll_done,volume,level_dbfs,peak,flags,knobs,note,note_valid,
                 frequency_bcd,song,cursor,fft_valid,xy_valid}=scenarios[n];
                selected_case=n;
            end
        end
    endtask
    integer fd,nread,case_id=0,xx,yy,dd,cc,n,count=0,checks=0,compat_checks=0,blank_checks=0;
    string vectors,ppm;
    reg [23:0] expected,previous_expected;
    reg previous_valid=0,previous_visible=0,previous_compare=0;
    integer previous_x=0,previous_y=0,previous_case=0;
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
                if(rgb!==previous_expected)
                    $fatal(1,"Literal pixel mismatch token%0d case%0d (%0d,%0d) actual%06h expected%06h",
                           checks,previous_case,previous_x,previous_y,rgb,previous_expected);
                if(previous_compare)begin
                    compat_checks=compat_checks+1;
                    if(rgb!==legacy_rgb)$fatal(1,"Feature0/1 LIVE/LIBRARY pixels differ case%0d (%0d,%0d)",
                                              previous_case,previous_x,previous_y);
                end
            end else if(rgb!==0)$fatal(1,"First pipeline stage not blank");
            previous_expected=want;previous_valid=1;
            previous_compare=!test_active && (page==0 || page==1);
            previous_x=tx;previous_y=ty;previous_case=tc;
        end
    endtask
    initial begin
        if($bits({page,mode,control_page,controls,test_active,sweep,overrun,requested,voices,index,
                  busy,gate,adc,calibrated,velocity,bend,modulation,pressure0,pressure1,timbre,
                  roll_active,roll_done,volume,level_dbfs,peak,flags,knobs,note,note_valid,
                  frequency_bcd,song,cursor,fft_valid,xy_valid})!=SCENARIO_BITS)$fatal(1,"Scenario width mismatch");
        if(!$value$plusargs("FFTMEM=%s",fft_file) || !$value$plusargs("XYMEM=%s",xy_file))
            $fatal(1,"Missing independent visualization fixtures");
        $readmemh(fft_file,fft_memory);$readmemh(xy_file,xy_memory);
        if(!$value$plusargs("STIMULI=%s",stimuli))$fatal(1,"Missing public input scenario memory");
        if(!$value$plusargs("CASE_COUNT=%d",case_count) || case_count<1 || case_count>128)
            $fatal(1,"Invalid scenario count");
        $readmemh(stimuli,scenarios,0,case_count-1);select_case(0);
        repeat(3)@(negedge clk);rst_n=1;
        if($value$plusargs("VECTORS=%s",vectors))begin
            fd=$fopen(vectors,"r");if(!fd)$fatal(1,"Cannot open independent oracle vectors");
            while(!$feof(fd))begin
                nread=$fscanf(fd,"%d %d %d %d %h\n",xx,yy,dd,cc,expected);
                if(nread==5)token(xx,yy,dd,cc,expected);
                else if(!$feof(fd))$fatal(1,"Malformed pixel vectors");
            end
            $fclose(fd);token(0,0,0,0,0);token(0,0,0,0,0);
            $display("V037_DISPLAY_PIXELS_PASS literal_checks=%0d compatibility=%0d",checks,compat_checks);
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
                        if(!test_active && (page==0 || page==1))begin
                            compat_checks=compat_checks+1;
                            if(rgb!==legacy_rgb)$fatal(1,"Feature0/1 raster difference scene%0d pixel%0d",case_id,count);
                        end
                        $fwrite(fd,"%c%c%c",rgb[23:16],rgb[15:8],rgb[7:0]);count=count+1;
                    end else begin blank_checks=blank_checks+1;if(rgb!==0)$fatal(1,"Raster blanking");end
                end
                previous_visible=de;previous_valid=1;
            end
            $fclose(fd);if(count!=640*480)$fatal(1,"Incomplete frame");
            $display("V037_DISPLAY_CAPTURE_PASS scene=%0d pixels=%0d blanking=%0d compatibility=%0d",
                     case_id,count,blank_checks,compat_checks);
        end
        $finish;
    end
    initial begin #100000000;$fatal(1,"V037 pixel timeout");end
endmodule
