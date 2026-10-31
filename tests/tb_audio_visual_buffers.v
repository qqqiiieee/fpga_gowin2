`timescale 1ns/1ps
module tb_audio_visual_buffers;
    reg clk27=0,pixel_clk=0,source_run=1,pixel_run=1;
    always #5 if(source_run)clk27=~clk27;else clk27=0;
    always #7 if(pixel_run)pixel_clk=~pixel_clk;else pixel_clk=0;
    reg source_rst_n=0,pixel_rst_n=0,frame_tick=0,sample_tick=0;
    reg signed [15:0] pcm=0,voice0=0,voice1=0;
    reg [7:0] fft_read_addr=0;reg [13:0] xy_read_addr=0;
    wire [7:0] fft_level;wire xy_dot,fft_valid,xy_valid;
    audio_visual_buffers dut(.clk27(clk27),.source_rst_n(source_rst_n),
        .pixel_clk(pixel_clk),.pixel_rst_n(pixel_rst_n),.frame_tick(frame_tick),
        .sample_tick(sample_tick),.pcm(pcm),.voice0(voice0),.voice1(voice1),
        .fft_read_addr(fft_read_addr),.xy_read_addr(xy_read_addr),
        .fft_level(fft_level),.xy_dot(xy_dot),.fft_valid(fft_valid),.xy_valid(xy_valid));
    reg expected_xy[0:16383];
    integer i,j,px,py,checks=0,clear_writes=0,capture_writes=0;
    reg old_fft_ack=0,old_xy_ack=0,old_frame=0;
    // Observe protocol invariants, not RAM contents. Expected pixel contents
    // below are computed from public samples using signed integer arithmetic.
    always @(posedge clk27)begin
        if(dut.source_ready[1])begin
            if(dut.bin_valid && !dut.fft_pending && fft_valid &&
                (!dut.fft_request)==dut.fft_ack)$fatal(1,"FFT displayed bank overwrite");
            if(dut.xy_write && xy_valid && (!dut.xy_request)==dut.xy_ack)
                $fatal(1,"XY displayed bank overwrite");
            if(dut.fft_pending && dut.fft_enable)$fatal(1,"FFT restarted pending ack");
            if(dut.frame_done && dut.fft_enable)$fatal(1,"FFT restarted on frame_done");
            if(dut.xy_write)begin
                if(dut.xy_state==0)clear_writes=clear_writes+1;
                else capture_writes=capture_writes+1;
            end
        end
    end
    always @(posedge pixel_clk)begin
        old_frame=frame_tick;old_fft_ack=dut.fft_ack;old_xy_ack=dut.xy_ack;
        #1;
        if(source_rst_n && pixel_rst_n && !old_frame &&
            (old_fft_ack!==dut.fft_ack || old_xy_ack!==dut.xy_ack))
            $fatal(1,"Bank changed away from frame_tick");
    end
    task reset_both;
        begin
            source_rst_n=0;pixel_rst_n=0;sample_tick=0;frame_tick=0;
            #3;if(fft_valid!==0 || xy_valid!==0 || fft_level!==0 || xy_dot!==0)
                $fatal(1,"Reset did not invalidate outputs");
            repeat(3)@(negedge clk27);
            source_rst_n=1;pixel_rst_n=1;
            repeat(6)@(negedge clk27);
        end
    endtask
    task pixel_frame;
        begin
            @(negedge pixel_clk);frame_tick=1;
            @(negedge pixel_clk);frame_tick=0;
        end
    endtask
    task capture;
        input integer pattern;
        integer n,v0,v1,c0,c1;
        begin
            wait(dut.xy_state==1);
            c0=clear_writes;c1=capture_writes;
            for(n=0;n<16384;n=n+1)expected_xy[n]=0;
            for(n=0;n<1024;n=n+1)begin
                case(pattern)
                    0:begin
                        // Four signed endpoints and zero, then an asymmetric
                        // pattern that cannot pass with duplicated voice0.
                        case(n)
                            0:begin v0=-32768;v1=-32768;end
                            1:begin v0=32767;v1=32767;end
                            2:begin v0=-32768;v1=32767;end
                            3:begin v0=32767;v1=-32768;end
                            4:begin v0=0;v1=0;end
                            default:begin v0=((n*512)%65536)-32768;
                                v1=(((n*3+17)*512)%65536)-32768;end
                        endcase
                    end
                    1:begin v0=5120;v1=-15872;end // (74,94), NOT diagonal.
                    default:begin v0=-10240;v1=20992;end // (44,22).
                endcase
                px=(v0+32768)/512;py=127-(v1+32768)/512;
                expected_xy[py*128+px]=1;
                @(negedge clk27);voice0=v0;voice1=v1;pcm=16'sd1234;sample_tick=1;
                @(negedge clk27);sample_tick=0;
                // Exactly 288 source clocks/sample, 27MHz / 288 = 93750Hz.
                if(n!=1023)repeat(286)@(negedge clk27);
            end
            repeat(4)@(negedge clk27);
            if(clear_writes!=c0 || capture_writes-c1!=1024)
                $fatal(1,"Capture count: clear=%0d count=%0d",clear_writes-c0,capture_writes-c1);
            if(!dut.xy_pending || !dut.fft_pending)$fatal(1,"Missing publication");
        end
    endtask
    task verify_xy;
        integer address;
        begin
            for(address=0;address<16384;address=address+1)begin
                @(negedge pixel_clk);xy_read_addr=address;
                @(posedge pixel_clk);#1;
                if(xy_dot!==expected_xy[address])
                    $fatal(1,"XY addr=%0d expected=%b got=%b",address,expected_xy[address],xy_dot);
                checks=checks+1;
            end
        end
    endtask
    task verify_fft;
        input integer serial;
        integer address;reg [7:0] expected;
        begin
            for(address=0;address<256;address=address+1)begin
                @(negedge pixel_clk);fft_read_addr=address;
                @(posedge pixel_clk);#1;expected=(address*29+serial*37)%256;
                if(fft_level!==expected)$fatal(1,"FFT addr=%0d expected=%0d got=%0d",address,expected,fft_level);
                checks=checks+1;
            end
        end
    endtask
    integer old_starts,saved_clear,saved_capture;
    reg [7:0] saved_q;
    initial begin
        // Create a real asserted-reset edge before checking async outputs;
        // declaration initializers alone need not trigger a derived reset net.
        #1;source_rst_n=1;pixel_rst_n=1;#1;
        reset_both();
        pixel_frame();
        if(fft_valid || xy_valid)$fatal(1,"First frame after reset must be invalid");
        capture(0);
        if(clear_writes!=16384)$fatal(1,"XY clear must cover exactly 16K cells");
        if(fft_valid || xy_valid || fft_level!==0 || xy_dot!==0)
            $fatal(1,"Unpublished memory leaked");
        old_starts=dut.u_fft.starts;saved_clear=clear_writes;saved_capture=capture_writes;
        // Stalled pixel clock: full completed frames must wait with no source
        // recapture or writes, even while new samples continue to arrive.
        @(negedge pixel_clk);pixel_run=0;
        repeat(400)begin
            @(negedge clk27);sample_tick=1;voice0=voice0+1;voice1=voice1-3;
        end
        sample_tick=0;
        if(dut.u_fft.starts!=old_starts || clear_writes!=saved_clear || capture_writes!=saved_capture)
            $fatal(1,"Unacked bank overwritten during stalled pixel clock");
        pixel_run=1;repeat(6)@(negedge pixel_clk);
        if(fft_valid || xy_valid)$fatal(1,"Swap happened before frame_tick");
        // Addresses stable before the first valid swap: q must come from the
        // newly published bank ON that same edge, not the uninitialized bank.
        xy_read_addr=127*128;fft_read_addr=73;
        pixel_frame();
        if(!xy_valid || !fft_valid || xy_dot!==1 || fft_level!==((73*29+37)%256))
            $fatal(1,"First swap bank/q/valid alignment");
        verify_xy();verify_fft(1);
        // Synchronous read: changing address alone cannot change q.
        @(negedge pixel_clk);fft_read_addr=3;
        @(posedge pixel_clk);#1;saved_q=fft_level;
        #1;fft_read_addr=9;#1;if(fft_level!==saved_q)$fatal(1,"RAM read is asynchronous");
        @(posedge pixel_clk);#1;if(fft_level!==((9*29+37)%256))$fatal(1,"RAM read latency");
        // Capture the other bank; old display remains identical without frame.
        capture(1);
        // Restore old expected image independently, without reading DUT RAM.
        for(i=0;i<16384;i=i+1)expected_xy[i]=0;
        expected_xy[127*128]=1;expected_xy[127]=1;expected_xy[0]=1;
        expected_xy[16383]=1;expected_xy[63*128+64]=1;
        for(i=5;i<1024;i=i+1)begin
            px=i%128;py=127-((i*3+17)%128);expected_xy[py*128+px]=1;
        end
        verify_xy();verify_fft(1);
        // Stalled source clock still permits pixel-side frame-boundary swap.
        @(negedge clk27);source_run=0;
        repeat(6)@(negedge pixel_clk);pixel_frame();
        for(i=0;i<16384;i=i+1)expected_xy[i]=0;
        expected_xy[94*128+74]=1;
        verify_xy();verify_fft(2);
        source_run=1;repeat(8)@(negedge clk27);
        // Reuse bank1: every old point must have been cleared before capture.
        capture(2);pixel_frame();verify_xy();verify_fft(3);
        // Video PLL loss while source clock is stopped: both control domains
        // invalidate asynchronously, and recover without a stale request/ack.
        @(negedge clk27);source_run=0;pixel_rst_n=0;
        #2;if(fft_valid || xy_valid || fft_level!==0 || xy_dot!==0)
            $fatal(1,"PLL loss did not invalidate");
        repeat(4)@(negedge pixel_clk);pixel_rst_n=1;
        repeat(6)@(negedge pixel_clk);pixel_frame();
        if(fft_valid || xy_valid)$fatal(1,"PLL restart exposed stale data");
        source_run=1;repeat(8)@(negedge clk27);capture(1);pixel_frame();
        verify_xy();verify_fft(1);
        // source_rst_n alone is the parent's video-PLL-loss reset route.
        @(negedge pixel_clk);pixel_run=0;source_rst_n=0;
        #2;if(fft_valid || xy_valid || fft_level!==0 || xy_dot!==0)
            $fatal(1,"source_rst_n did not reset stalled pixel domain");
        repeat(4)@(negedge clk27);source_rst_n=1;
        repeat(6)@(negedge clk27);pixel_run=1;
        repeat(6)@(negedge pixel_clk);
        if(fft_valid || xy_valid)$fatal(1,"Source reset stale valid");
        capture(2);
        // Source completed before the very first pixel frame after reset.
        // That first boundary is nevertheless invalid and must not ack either
        // bank; the following frame can accept both completed publications.
        pixel_frame();
        if(fft_valid || xy_valid || fft_level!==0 || xy_dot!==0)
            $fatal(1,"First frame published too early after stalled-clock reset");
        pixel_frame();verify_xy();verify_fft(1);
        $display("AUDIO_VISUAL_BUFFERS_PASS checks=%0d Fs=93750 clear16K capture1024 stalled_clocks immutable_banks reset_recovery",checks);
        $finish;
    end
    initial begin #50000000;$fatal(1,"Buffers timeout");end
endmodule

// TEST ONLY deterministic FFT protocol producer. No transform or production
// substitute: the real audio_fft512.v belongs to the separate FFT workstream.
module audio_fft512(
    input clk,rst_n,sample_tick,input signed [15:0] pcm,input enable,
    output reg bin_valid,output reg [7:0] bin_index,bin_level,
    output reg frame_done,output reg busy
);
    integer starts;reg [7:0] counter;reg finishing;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            starts<=0;bin_valid<=0;bin_index<=0;bin_level<=0;
            frame_done<=0;busy<=0;counter<=0;finishing<=0;
        end else begin
            bin_valid<=0;frame_done<=0;
            if(!busy)begin
                if(enable && sample_tick)begin busy<=1;counter<=0;starts<=starts+1;end
            end else if(finishing)begin
                frame_done<=1;busy<=0;finishing<=0;
            end else begin
                bin_valid<=1;bin_index<=counter;bin_level<=counter*29+starts*37;
                counter<=counter+1'b1;if(counter==255)finishing<=1;
            end
        end
    end
endmodule
