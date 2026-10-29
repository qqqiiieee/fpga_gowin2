`timescale 1ns/1ps
module tb_hdmi_normal_miter;
    reg [9:0] x, y;
    reg de;
    reg [11:0] keys;
    reg [3:0] timbre;
    reg [6:0] note;
    reg note_valid;
    reg [15:0] frequency_bcd;
    reg [7:0] volume_percent;
    reg signed [7:0] level_dbfs;
    reg [7:0] peak_percent;
    reg signed [8:0] pitch;
    reg [5:0] voices;
    reg [7:0] pressure0, pressure1, flags;
    reg guide_active, guide_done;
    reg [11:0] cue_mask, next_mask, wrong_mask;
    reg [5:0] guide_step, guide_total;
    reg [7:0] beat_progress;
    reg [1:0] target_beats;
    reg signed [15:0] wave_current, wave_previous;
    reg [3:0] scope_gain;
    reg wave_valid;
    wire [7:0] red, green, blue;
    hdmi_instrument_dashboard dut(
        .x(x), .y(y), .de(de), .keys(keys), .timbre(timbre),
        .note(note), .note_valid(note_valid), .frequency_bcd(frequency_bcd),
        .volume_percent(volume_percent), .level_dbfs(level_dbfs),
        .peak_percent(peak_percent), .pitch(pitch), .voices(voices),
        .pressure0(pressure0), .pressure1(pressure1), .flags(flags),
        .guide_active(guide_active), .guide_done(guide_done),
        .cue_mask(cue_mask), .next_mask(next_mask), .wrong_mask(wrong_mask),
        .guide_step(guide_step), .guide_total(guide_total),
        .beat_progress(beat_progress), .target_beats(target_beats),
        .wave_current(wave_current), .wave_previous(wave_previous),
        .scope_gain(scope_gain), .wave_valid(wave_valid),
        .red(red), .green(green), .blue(blue),
        .test_active(1'b0), .test_requested(6'd0), .test_busy(32'd0), .test_gate(32'd0),
        .test_sweep(1'b0), .test_index(5'd0), .test_overrun(1'b0)
    );

    wire [7:0] golden_red,golden_green,golden_blue;
    hdmi_baseline_dashboard golden(
        .x(x), .y(y), .de(de), .keys(keys), .timbre(timbre),
        .note(note), .note_valid(note_valid), .frequency_bcd(frequency_bcd),
        .volume_percent(volume_percent), .level_dbfs(level_dbfs),
        .peak_percent(peak_percent), .pitch(pitch), .voices(voices),
        .pressure0(pressure0), .pressure1(pressure1), .flags(flags),
        .guide_active(guide_active), .guide_done(guide_done),
        .cue_mask(cue_mask), .next_mask(next_mask), .wrong_mask(wrong_mask),
        .guide_step(guide_step), .guide_total(guide_total),
        .beat_progress(beat_progress), .target_beats(target_beats),
        .wave_current(wave_current), .wave_previous(wave_previous),
        .scope_gain(scope_gain), .wave_valid(wave_valid),
        .red(golden_red), .green(golden_green), .blue(golden_blue)
    );

    // RTL SIMULATION PREVIEW, never a board capture or hardware screenshot.
    // Run this top alone. +PPM=<path> writes P3 pixels to a parent-selected path;
    // omit +PPM to stream P3 to stdout (simulator messages may surround it).
    // +SCENE=0 guide, 1 free, 2 finished, 3 WAIT, 4 wrong, 5 clipping extremes.
    integer output_file, px, py, address, scene;
    reg [2047:0] output_path;

    function signed [15:0] simulated_sample;
        input integer index;
        integer phase, amplitude;
        begin
            amplitude=$rtoi(12000.0*$sin(6.283185307179586*261.626*index*4.0/93750.0));
            simulated_sample=amplitude;
        end
    endfunction

    initial begin
        scene=0;
        if ($value$plusargs("SCENE=%d",scene)) begin end
        output_file=32'h80000001;
        if ($value$plusargs("PPM=%s",output_path)) begin
            output_file=$fopen(output_path,"w");
            if(output_file==0) begin $display("PREVIEW_FAIL cannot open requested PPM"); $finish; end
        end
        de=1; keys=12'h001; timbre=0; note=60; note_valid=1; frequency_bcd=16'h0262;
        volume_percent=73; level_dbfs=-12; peak_percent=37; pitch=0; voices=1;
        pressure0=88; pressure1=164; flags=8'h24;
        guide_active=1; guide_done=0; cue_mask=1; next_mask=1; wrong_mask=0;
        guide_step=1; guide_total=42; beat_progress=150; target_beats=1;
        scope_gain=1; wave_valid=1; wave_current=0; wave_previous=0;
        case(scene)
            1: begin guide_active=0; keys=12'h481; timbre=15; end
            2: begin guide_done=1; guide_step=42; beat_progress=255; keys=0; end
            3: begin wave_valid=0; note_valid=0; keys=0; flags=8'h18; end
            4: begin keys=12'h003; wrong_mask=2; flags=8'hc0; end
            5: begin scope_gain=15; level_dbfs=-128; pitch=-256; flags=8'hff; end
        endcase
        $fwrite(output_file,"P3\n# RTL simulation of hdmi_instrument_dashboard; synthetic PCM\n640 480\n255\n");
        for(py=0;py<480;py=py+1) begin
            for(px=0;px<640;px=px+1) begin
                x=px; y=py;
                // Emulates the parent's already aligned sample-pair interface.
                address=0;
                if(px>=32 && px<=543) address=(px-32)>>1;
                wave_current=simulated_sample(address);
                wave_previous=simulated_sample(address==0 ? 0 : address-1);
                if(scene==5) begin wave_current=32767; wave_previous=-32768; end
                #1;
                if ({red,green,blue} !== {golden_red,golden_green,golden_blue})
                    $fatal(1,"Normal frame differs from baseline: scene=%0d x=%0d y=%0d",scene,px,py);
                $fwrite(output_file,"%0d %0d %0d\n",red,green,blue);
            end
        end
        if(output_file != 32'h80000001) begin
            $fclose(output_file);
            $display("HDMI_NORMAL_BASELINE_MITER_PASS RTL simulation scene=%0d",scene);
        end
        $finish;
    end
endmodule
