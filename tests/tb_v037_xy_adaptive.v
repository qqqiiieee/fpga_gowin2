`timescale 1ns/1ps
// Independent V037 gain/coordinate oracle. FFT protocol stub is compiled from
// the UNMODIFIED old buffer bench with -s tb_v037_xy_adaptive (old top unused).
module tb_v037_xy_adaptive;
    reg clk27=0,pixel_clk=0,source_run=1,pixel_run=1;
    always #5 if(source_run)clk27=~clk27;else clk27=0;
    always #7 if(pixel_run)pixel_clk=~pixel_clk;else pixel_clk=0;
    reg source_rst_n=1,pixel_rst_n=1,frame_tick=0,sample_tick=0;
    reg signed [15:0] pcm=0,voice0=0,voice1=0;
    reg [7:0] fft_read_addr=0;reg [13:0] xy_read_addr=0;
    wire [7:0] fft_level;wire xy_dot,fft_valid,xy_valid;
    audio_visual_buffers #(.XY_AUTO_SCALE(1)) dut(.clk27(clk27),.source_rst_n(source_rst_n),
        .pixel_clk(pixel_clk),.pixel_rst_n(pixel_rst_n),.frame_tick(frame_tick),
        .sample_tick(sample_tick),.pcm(pcm),.voice0(voice0),.voice1(voice1),
        .fft_read_addr(fft_read_addr),.xy_read_addr(xy_read_addr),.fft_level(fft_level),
        .xy_dot(xy_dot),.fft_valid(fft_valid),.xy_valid(xy_valid));
    reg expected_capture[0:16383],expected_display[0:16383];
    integer model_gain=0,model_up=0,model_peak=0,capture_gain=0;
    integer checks=0,frames=0,sample_checks=0,clear_writes=0,point_writes=0;
    integer gain_seen=0,saturated=0,zero_frames=0,minnegative=0;
    integer old_gain,old_state,old_ack0,old_ack1;
    reg capturing=0,display_known=0,was_ready,was_frame;
    // Gain expectation is state derived only from prior PUBLIC input samples.
    // Internal gain is observed only for boundary/state invariants; NEVER used
    // by expected coordinate/bitmap calculations.
    always @(posedge clk27)begin
        was_ready=dut.source_ready[1];old_gain=dut.xy_scale_shift;old_state=dut.xy_state;
        if(was_ready)begin
            if(dut.xy_write)begin
                if(xy_valid && (!dut.xy_request)==dut.xy_ack)$fatal(1,"Displayed bank overwritten");
                if(dut.xy_state==0)clear_writes=clear_writes+1;
                else point_writes=point_writes+1;
            end
            if(sample_tick && dut.u_fft.pcm!==pcm)$fatal(1,"PCM changed on FFT branch");
            if(dut.fft_pending && dut.fft_enable)$fatal(1,"FFT pending enable");
            if(capturing && dut.xy_state==1 && dut.xy_scale_shift!==capture_gain[2:0])
                $fatal(1,"Mixed gain within1024point frame");
        end
        #1;
        if(was_ready && dut.source_ready[1])begin
            if(dut.xy_scale_shift>4)$fatal(1,"Gain exceeds x16");
            if(dut.xy_scale_shift!==old_gain[2:0] && old_state!=2)
                $fatal(1,"Gain changed away from XY_PUBLISH");
        end
    end
    always @(posedge pixel_clk)begin
        old_ack0=dut.xy_ack;old_ack1=dut.fft_ack;was_frame=frame_tick;
        #1;
        if(source_rst_n && pixel_rst_n && dut.pixel_ready[1] && !was_frame &&
            (old_ack0!==dut.xy_ack || old_ack1!==dut.fft_ack))$fatal(1,"Midframe bank swap");
    end
    function integer coordinate;
        input integer sample_value,shift;
        integer wide;
        begin
            wide=sample_value*(2**shift);
            if(wide>32767)wide=32767;
            if(wide< -32768)wide=-32768;
            // Nonnegative division gives exact floor(signed/512)+64, including
            // -1,-511,-512,-513. No Verilog signed / truncation approximation.
            coordinate=(wide+32768)/512;
        end
    endfunction
    function integer wanted;
        input integer peak;
        begin
            if(peak<256)wanted=0;
            else if(peak<=1536)wanted=4;
            else if(peak<=3072)wanted=3;
            else if(peak<=6144)wanted=2;
            else if(peak<=12288)wanted=1;
            else wanted=0;
        end
    endfunction
    task update_model;
        integer target;
        begin
            target=wanted(model_peak);
            if(model_peak<256 || target<model_gain)begin model_gain=target;model_up=0;end
            else if(target>model_gain)begin
                if(model_up==1)begin model_gain=model_gain+1;model_up=0;end
                else model_up=1;
            end else model_up=0;
        end
    endtask
    task frame;
        begin @(negedge pixel_clk);frame_tick=1;@(negedge pixel_clk);frame_tick=0;end
    endtask
    task reset_pair;
        begin
            source_rst_n=0;pixel_rst_n=0;sample_tick=0;frame_tick=0;capturing=0;
            model_gain=0;model_up=0;display_known=0;
            #2;if(xy_valid!==0 || fft_valid!==0 || xy_dot!==0 || fft_level!==0)
                $fatal(1,"Async reset validity");
            repeat(4)@(negedge clk27);source_rst_n=1;pixel_rst_n=1;
            repeat(8)@(negedge clk27);
            if(dut.xy_scale_shift!==0)$fatal(1,"Reset gain not x1");
        end
    endtask
    // Most gain sequences use4 clocks/sample (no dependence on wall time).
    // Separate frames below run288clocks/sample, nominal27MHz/288=Fs93750.
    task capture_frame;
        input integer pattern,amplitude,cadence;
        integer n,a,b,ax,ay,index,mag0,mag1,clear_before,points_before;
        begin
            wait(dut.xy_state==1);
            capture_gain=model_gain;model_peak=0;capturing=1;
            clear_before=clear_writes;points_before=point_writes;
            if(dut.xy_scale_shift!==capture_gain[2:0])$fatal(1,"Capture gain differs from independent model");
            gain_seen=gain_seen | (1<<capture_gain);
            for(index=0;index<16384;index=index+1)expected_capture[index]=0;
            for(n=0;n<1024;n=n+1)begin
                case(pattern)
                    0:begin a=(n%2==0)?amplitude:-amplitude;
                        b=(n%4<2)?amplitude/2:-amplitude/2;end
                    1:begin a=(n%2==0)?amplitude/16:-amplitude/16;
                        b=(n%4<2)?amplitude:-amplitude;end
                    2:begin // Last sample alone must dominate frame peak.
                        a=(n%2==0)?1000:-1000;b=(n%4<2)?500:-500;
                        if(n==1023)begin a=-32768;b=32767;end
                    end
                    3:begin // Loud attack while previous gain is high.
                        case(n%8)
                            0:begin a=-32768;b=32767;end
                            1:begin a=32767;b=-32768;end
                            2:begin a=4096;b=-4096;end
                            3:begin a=-4096;b=4096;end
                            4:begin a=2047;b=-2048;end
                            5:begin a=-2049;b=2048;end
                            6:begin a=-1;b=-513;end
                            7:begin a=-511;b=-512;end
                        endcase
                    end
                    4:begin a=0;b=0;end
                    5:begin a=(n%2==0)?255:-255;b=(n%4<2)?1:-1;end
                    default:begin
                        a=((n*1297+23)%(2*amplitude+1))-amplitude;
                        b=((n*593+67)%(2*amplitude+1))-amplitude;
                        if(n==0)a=-amplitude;if(n==1023)b=amplitude;
                    end
                endcase
                // Integer public stimulus and model, no DUT arithmetic oracle.
                mag0=a<0?-a:a;mag1=b<0?-b:b;
                if(mag0>model_peak)model_peak=mag0;
                if(mag1>model_peak)model_peak=mag1;
                if(a==-32768 || b==-32768)minnegative=minnegative+1;
                if(a*(2**capture_gain)>32767 || a*(2**capture_gain)< -32768 ||
                   b*(2**capture_gain)>32767 || b*(2**capture_gain)< -32768)saturated=saturated+1;
                ax=coordinate(a,capture_gain);ay=127-coordinate(b,capture_gain);
                expected_capture[ay*128+ax]=1;
                @(negedge clk27);voice0=a;voice1=b;pcm=(n*197+31)%65536;sample_tick=1;
                @(negedge clk27);sample_tick=0;
                if(n!=1023)repeat(cadence-2)@(negedge clk27);
                sample_checks=sample_checks+1;
            end
            capturing=0;update_model();
            repeat(5)@(negedge clk27);
            if(clear_writes!=clear_before || point_writes-points_before!=1024)
                $fatal(1,"Capture length or clear overlap");
            if(!dut.xy_pending || dut.xy_scale_shift!==model_gain[2:0])
                $fatal(1,"Publish adaptation frame=%0d peak=%0d target=%0d gain=%0d/%0d",
                    frames,model_peak,wanted(model_peak),dut.xy_scale_shift,model_gain);
            if(pattern==4)begin
                zero_frames=zero_frames+1;
                if(expected_capture[63*128+64]!==1 || model_gain!=0)$fatal(1,"Zero frame not center/x1");
            end
            frames=frames+1;
        end
    endtask
    task verify_bitmap;
        input integer current_capture;
        integer address;
        reg expected,held;
        begin
            for(address=0;address<16384;address=address+1)begin
                @(negedge pixel_clk);xy_read_addr=address;
                @(posedge pixel_clk);#1;
                expected=current_capture ? expected_capture[address] : expected_display[address];
                if(xy_dot!==expected)$fatal(1,"Bitmap frame=%0d gain=%0d addr=%0d expected=%b got=%b",
                    frames,capture_gain,address,expected,xy_dot);
                checks=checks+1;
            end
            // Address changes between posedges must not change synchronous q.
            @(negedge pixel_clk);xy_read_addr=0;
            @(posedge pixel_clk);#1;held=xy_dot;
            #1;xy_read_addr=8191;#1;if(xy_dot!==held)$fatal(1,"Asynchronous RAM read");
        end
    endtask
    task publish;
        integer j;
        begin
            repeat(4)@(negedge pixel_clk);frame();
            if(!xy_valid)$fatal(1,"No valid publication");
            verify_bitmap(1);
            for(j=0;j<16384;j=j+1)expected_display[j]=expected_capture[j];
            display_known=1;
        end
    endtask
    task exercise;
        input integer pattern,amplitude;
        begin capture_frame(pattern,amplitude,4);publish();end
    endtask
    integer k,saved_clear,saved_points,saved_gain,saved_starts;
    initial begin
        #1;reset_pair();frame();if(xy_valid || fft_valid)$fatal(1,"First reset frame valid");
        exercise(4,0);
        for(k=0;k<8;k=k+1)exercise(k%2,1000); // two frames per x2 increase.
        if(model_gain!=4)$fatal(1,"Slow release failed to reach x16");
        exercise(0,1536); // +/-1536 atx16 =>X16..112, span96/128.
        // Voice1 is half Voice0: +768*x16 =>Y39, while X spans16..112.
        if(!expected_display[39*128+112] || !expected_display[39*128+16])
            $fatal(1,"Shared gain pair scale/ratio or96pixel span");
        exercise(3,0); // one high-gain clipped frame, then immediate x1.
        if(model_gain!=0)$fatal(1,"Loud attack did not drop immediately");
        for(k=0;k<4;k=k+1)exercise(0,1000);
        exercise(2,0); // -32768 on FINAL sample must force immediate x1.
        if(model_gain!=0 || model_peak!=32768)$fatal(1,"Last sample / minnegative peak lost");
        // Every exact threshold and adjacent magnitude; alternating axes also
        // distinguishes max(pair) from sum/RMS/axis-independent normalization.
        exercise(0,255);exercise(1,256);
        exercise(0,1535);exercise(1,1536);exercise(0,1537);
        exercise(1,3071);exercise(0,3072);exercise(1,3073);
        exercise(0,6143);exercise(1,6144);exercise(0,6145);
        exercise(1,12287);exercise(0,12288);exercise(1,12289);exercise(0,32767);
        // An equal/quiet/lower desired frame breaks the upward streak.
        exercise(0,1000);exercise(0,20000);exercise(0,1000);
        if(model_gain!=0)$fatal(1,"Interrupted upward streak advanced");
        exercise(0,1000);if(model_gain!=1)$fatal(1,"Two-frame rise not one step");
        exercise(0,10000); // equal desired=1 must clear pending.
        exercise(0,1000);exercise(0,10000);exercise(0,1000);
        if(model_gain!=1)$fatal(1,"Equal desired did not break streak");
        exercise(5,0);exercise(4,0);exercise(5,0);exercise(4,0);
        if(model_gain!=0)$fatal(1,"Noise/silence gained up");
        // Rich asymmetric points at each stable gain exercise quantization,
        // negative floors and ratio preservation over thousands of addresses.
        for(k=0;k<8;k=k+1)exercise(6,1200);
        exercise(6,1536);
        // Pending bank & gain must be immutable with pixel clock stopped.
        capture_frame(1,600,288);verify_bitmap(0);
        @(negedge pixel_clk);pixel_run=0;
        saved_clear=clear_writes;saved_points=point_writes;
        saved_gain=dut.xy_scale_shift;saved_starts=dut.u_fft.starts;
        repeat(1000)begin @(negedge clk27);sample_tick=1;voice0=-32768;voice1=32767;end
        sample_tick=0;
        if(clear_writes!=saved_clear || point_writes!=saved_points || dut.xy_scale_shift!=saved_gain ||
            dut.u_fft.starts!=saved_starts)$fatal(1,"Pending/stalled bank changed");
        pixel_run=1;repeat(6)@(negedge pixel_clk);verify_bitmap(0);publish();
        // Source stopped: pixel publication must still read the complete bank.
        capture_frame(6,700,4);@(negedge clk27);source_run=0;
        publish();source_run=1;repeat(8)@(negedge clk27);
        // Reset while pixel clock is stopped; first boundary stays invalid
        // even when the source already completed its first post-reset frame.
        @(negedge pixel_clk);pixel_run=0;source_rst_n=0;model_gain=0;model_up=0;
        #2;if(xy_valid!==0 || xy_dot!==0 || dut.xy_scale_shift!==0)$fatal(1,"Stalled pixel reset");
        repeat(4)@(negedge clk27);source_rst_n=1;repeat(8)@(negedge clk27);
        capture_frame(4,0,288);pixel_run=1;repeat(8)@(negedge pixel_clk);frame();
        if(xy_valid || xy_dot!==0)$fatal(1,"First post-reset frame must be invalid");
        publish();
        // Pixel PLL loss with source clock stopped invalidates asynchronously.
        @(negedge clk27);source_run=0;pixel_rst_n=0;model_gain=0;model_up=0;
        #2;if(xy_valid!==0 || xy_dot!==0 || dut.xy_scale_shift!==0)$fatal(1,"Stalled source PLL reset");
        repeat(4)@(negedge pixel_clk);pixel_rst_n=1;repeat(8)@(negedge pixel_clk);frame();
        if(xy_valid)$fatal(1,"PLL loss stale first frame");
        source_run=1;repeat(8)@(negedge clk27);exercise(6,1000);
        if(gain_seen!=31 || saturated<100 || minnegative<100 || zero_frames<3 || frames<50)
            $fatal(1,"Coverage incomplete gains=%0d sat=%0d min=%0d zeros=%0d frames=%0d",
                gain_seen,saturated,minnegative,zero_frames,frames);
        $display("V037_XY_ADAPTIVE_PASS frames=%0d bitmap_checks=%0d samples=%0d gain_mask=%0d saturated=%0d minnegative=%0d",
            frames,checks,sample_checks,gain_seen,saturated,minnegative);$finish;
    end
    initial begin #100000000;$fatal(1,"Bounded adaptive regression timeout");end
endmodule
