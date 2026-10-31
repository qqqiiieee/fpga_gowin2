`timescale 1ns/1ps
// Algorithm/integration bench: clocks are always real clk edges, never a DUT
// generated clock. +period=288 reproduces the 27MHz/93750Hz sample enable.
module tb_audio_fft512;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, sample_tick=0, enable=0;
    reg signed [15:0] pcm=0;
    wire bin_valid, frame_done, busy;
    wire [7:0] bin_index, bin_level;
    audio_fft512 dut(clk,rst_n,sample_tick,pcm,enable,
                     bin_valid,bin_index,bin_level,frame_done,busy);

    reg [15:0] stimulus [0:262143];
    reg [2047:0] input_path, output_path;
    integer period, frames, fd, frame, i, j, count, cycles=0;
    integer first_cycle, last_bin_cycle, butterfly_writes, done_count=0;
    integer total_samples=0, last_sample_cycle, finished_cycle;
    integer abort_mode, abort_at, watchdog=0;
    reg last_valid=0, last_done=0;

    task send_sample;
        input [15:0] value;
        begin
            @(negedge clk); pcm=value; sample_tick=1;
            @(negedge clk); sample_tick=0;
            repeat(period-2) @(negedge clk);
        end
    endtask
    task reset_dut;
        begin
            @(negedge clk); rst_n=0; sample_tick=0; enable=0;
            repeat(3) @(negedge clk);
            rst_n=1;
            repeat(2) @(negedge clk);
            if (busy || bin_valid || frame_done) $fatal(1,"reset outputs");
        end
    endtask

    always @(posedge clk) begin
        cycles=cycles+1;
        if (rst_n && sample_tick && dut.state==dut.CAPTURE &&
            dut.index==511 && dut.phase==7) last_sample_cycle=cycles;
        if (rst_n && dut.state==dut.BF_VIM) butterfly_writes=butterfly_writes+1;
        #1;
        if (rst_n) begin
            if (bin_valid) begin
                if (last_valid) $fatal(1,"bin_valid must be a pulse");
                if (!busy) $fatal(1,"busy dropped during bin output");
                if (bin_index !== count[7:0] || count>=256) $fatal(1,"bin order/count");
                if ((^bin_level)===1'bx) $fatal(1,"unknown bin_level");
                $fdisplay(fd,"BIN %0d %0d %0d %0d %0d",frame,bin_index,bin_level,
                    $signed(dut.data_memory[{bin_index,1'b0}]),
                    $signed(dut.data_memory[{bin_index,1'b1}]));
                count=count+1;
                last_bin_cycle=cycles;
            end
            if (frame_done) begin
                if (last_done || bin_valid || count!=256) $fatal(1,"done pulse/order");
                if (cycles!=last_bin_cycle+1) $fatal(1,"done must follow final bin");
                if (busy) $fatal(1,"busy not idle at done");
                if (butterfly_writes!=2304) $fatal(1,"not 2304 radix2 butterflies");
                done_count=done_count+1;
                finished_cycle=cycles;
                $fdisplay(fd,"DONE %0d %0d %0d %0d",frame,
                    cycles-first_cycle,last_sample_cycle-first_cycle,butterfly_writes);
            end
        end
        last_valid=bin_valid;
        last_done=frame_done;
    end

    initial begin
        period=4; frames=1; abort_mode=0;
        if (!$value$plusargs("input=%s",input_path)) $fatal(1,"input plusarg");
        if (!$value$plusargs("output=%s",output_path)) $fatal(1,"output plusarg");
        i=$value$plusargs("period=%d",period);
        i=$value$plusargs("frames=%d",frames);
        i=$value$plusargs("abort=%d",abort_mode);
        if (period<4 || frames<1 || frames>64) $fatal(1,"unsupported bench settings");
        $readmemh(input_path,stimulus,0,frames*4096-1);
        fd=$fopen(output_path,"w");
        if (!fd) $fatal(1,"cannot open output");
        count=0; butterfly_writes=0; frame=0;
        reset_dut;
        // Disabled PCM must never admit a frame.
        repeat(12) send_sample(16'h8000);
        if (busy || count || done_count) $fatal(1,"disabled frame admitted");
        if (abort_mode) begin
            enable=1;
            abort_at=(abort_mode==1) ? 777 : 4096;
            for (i=0;i<abort_at;i=i+1) send_sample(16'h8000);
            if (abort_mode==2) repeat(113) @(negedge clk);
            if (!busy) $fatal(1,"abort test never started");
            reset_dut;
            repeat(12) send_sample(16'h7fff);
            if (count || done_count || busy) $fatal(1,"aborted frame leaked output");
            butterfly_writes=0;
        end
        for (frame=0;frame<frames;frame=frame+1) begin
            count=0; butterfly_writes=0; first_cycle=cycles+1;
            enable=1;
            for (i=0;i<4096;i=i+1) begin
                send_sample(stimulus[frame*4096+i]);
                if (i==31) enable=0; // rest of frame must ignore enable
            end
            if (!busy) $fatal(1,"FFT never busy");
            watchdog=0;
            // Continue sample enables while computing: these must be ignored.
            while (done_count<=frame && watchdog<40000) begin
                send_sample(16'h7fff);
                watchdog=watchdog+period;
            end
            if (done_count!=frame+1) $fatal(1,"FFT timeout");
            repeat(12) send_sample(16'h8000);
            if (busy || count!=256 || done_count!=frame+1) $fatal(1,"disabled repeat frame");
        end
        $fclose(fd);
        $display("FFT512_BENCH_PASS frames=%0d period=%0d abort=%0d",frames,period,abort_mode);
        $finish;
    end
    initial begin #100000000; $fatal(1,"global timeout"); end
endmodule
