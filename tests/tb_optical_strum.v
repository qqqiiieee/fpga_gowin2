`timescale 1ns/1ps
// All beam transitions below are off-clock, through the real two-stage CDC and
// real filters. No force/deposit or internal timer shortcuts, including PRODUCTION.
module tb_optical_strum;
    parameter PRODUCTION=0;
    localparam HZ=PRODUCTION?27000000:10000;
    localparam F=PRODUCTION?27000:3;
    localparam S=PRODUCTION?5400000:20;
    localparam MS=HZ/1000, P=150*MS;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0, suppress=0;
    reg [1:0] beams=0;
    wire trigger, reverse, ready;
    wire [7:0] velocity;
    wire [3:0] gap_ms;
    wire [1:0] blocked,electrical_level;
    optical_strum #(.CLK_HZ(HZ),.FILTER_CYCLES(F),.STARTUP_CYCLES(S),
        .PAIR_WINDOW_CYCLES(P)) dut(.*);
    integer cycles=0, events=0, checks=0;
    integer last_cycle=0, last_v=0, last_gap=0, last_reverse=0;
    reg last_trigger=0;
    always @(posedge clk) begin
        cycles=cycles+1;
        #1;
        if(rst_n) begin
            if(trigger && last_trigger) $fatal(1,"trigger wider than one clock");
            if(trigger && suppress) $fatal(1,"trigger during suppress");
            if(trigger) begin
                events=events+1; last_cycle=cycles;
                last_v=velocity; last_gap=gap_ms; last_reverse=reverse;
            end
        end
        last_trigger=trigger;
    end
    task tick;
        input integer n;
        begin repeat(n) @(posedge clk); #2; end
    endtask
    task check;
        input condition;
        input [511:0] message;
        begin if(condition!==1'b1) $fatal(1,"%0s cycle=%0d",message,cycles);
            checks=checks+1; end
    endtask
    task drive;
        input [1:0] value;
        begin @(negedge clk); #2; beams=value; end
    endtask
    task boot;
        input [1:0] idle_value;
        integer start;
        begin
            @(negedge clk); #2; rst_n=0; beams=idle_value; suppress=0;
            tick(4); @(negedge clk); #2; rst_n=1; start=cycles;
            tick(S-1); check(!ready,"startup cannot finish before S cycles");
            while(!ready && cycles-start<S+F+20) tick(1);
            check(ready,"startup ready timeout");
            check(blocked==0,"learned baseline must be idle"); tick(4);
        end
    endtask
    task release_both;
        input [1:0] idle_value;
        begin drive(idle_value); tick(F+8); check(blocked==0,"release/rearm"); end
    endtask
    task await_event;
        input integer previous;
        input integer limit;
        integer start;
        begin start=cycles;
            while(events==previous && cycles-start<limit) tick(1);
            check(events==previous+1,"exactly one expected gesture");
        end
    endtask
    task pair_test;
        input [1:0] idle_value;
        input integer backwards, delta, want_v, want_gap;
        integer before_events;
        reg [1:0] first;
        begin
            release_both(idle_value); before_events=events;
            first=backwards?2'b10:2'b01;
            drive(idle_value ^ first);
            repeat(delta) @(negedge clk); #2; beams=idle_value^2'b11;
            await_event(before_events,F+12);
            check(last_reverse==backwards,"pair direction");
            check(last_v==want_v && last_gap==want_gap,"velocity/gap bin");
            tick(F+5); check(events==before_events+1,"paired event cannot repeat");
        end
    endtask
    integer before_events,start,first_edge;
    initial begin
        tick(3); boot(2'b00);
        if(PRODUCTION) begin
            // Actual 27MHz cycle counts, including the full 5.4M-cycle startup,
            // 27k-cycle filter, 4.05M-cycle timeout, and inclusive 8ms speed bin.
            before_events=events; drive(2'b01); start=cycles;
            tick(F+1); check(blocked==0,"production filter not early");
            tick(1); check(blocked==1,"production filter exact F after CDC");
            first_edge=start+F+3;
            while(cycles<first_edge+P-1) tick(1);
            check(events==before_events,"production fallback not before 150ms");
            tick(1); check(events==before_events+1,"production 150ms fallback boundary");
            check(last_cycle==first_edge+P,"production timeout exact cycle");
            check(last_v==160 && last_gap==8 && last_reverse==0,"production fallback data");
            pair_test(0,0,8*MS,255,2);
            $display("PASS tb_optical_strum production checks=%0d cycles=%0d",checks,cycles);
        end else begin
            pair_test(0,0,8*MS,255,2);
            pair_test(0,1,8*MS+1,220,4);
            pair_test(0,0,20*MS,220,4);
            pair_test(0,1,20*MS+1,180,6);
            pair_test(0,0,50*MS,180,6);
            pair_test(0,1,50*MS+1,140,10);
            pair_test(0,0,P,140,10); // opposite edge wins at exact timeout
            release_both(0); before_events=events; drive(3);
            await_event(before_events,F+12);
            check(last_reverse==0 && last_v==180 && last_gap==6,"simultaneous default");
            tick(2*P); check(events==before_events+1,"long obstruction no repeats/adaptation");
            check(blocked==3,"long obstruction remains blocked");
            // Releasing only one line must not rearm the pair.
            drive(2); tick(F+8); drive(3); tick(P+F+8);
            check(events==before_events+1,"both beams must release before rearm");
            release_both(0); before_events=events; drive(1); start=cycles;
            tick(F+P+2); check(events==before_events,"single line waits whole window");
            tick(1); check(events==before_events+1,"single A timeout");
            check(last_cycle==start+F+3+P,"fallback exact clock");
            check(last_reverse==0 && last_v==160 && last_gap==8,"fallback data");
            tick(2*P); check(events==before_events+1,"single held no repeat");
            release_both(0); before_events=events; drive(2);
            await_event(before_events,P+F+12);
            check(last_reverse==0 && last_v==160,"single B usable fallback");
            release_both(0); before_events=events;
            // Repeated F-1-clock bounce is rejected independently on each line.
            repeat(8) begin drive(1); tick(F-1); drive(0); tick(F+2); end
            check(blocked==0 && events==before_events,"short bounce rejected");
            drive(1); tick(F+6); // A stays blocked while B chatters
            repeat(4) begin drive(3); tick(F-1); drive(1); tick(F+2); end
            check(blocked==1,"B chatter does not reset A filter");
            drive(3); await_event(before_events,F+12);
            release_both(0); before_events=events;
            drive(1); tick(F+10); suppress=1; tick(P+5);
            check(events==before_events,"suppress cancels pending fallback");
            suppress=0; tick(P+10); drive(3); tick(P+F+10);
            check(events==before_events,"suppress exit waits full release");
            release_both(0); pair_test(0,1,5*MS,255,2);
            before_events=events; suppress=1; drive(0); tick(F+8);
            drive(3); tick(P+F+10); drive(0); tick(F+8); suppress=0;
            tick(P+5); check(events==before_events,"gestures during suppress never replay");
            pair_test(0,0,12*MS,220,4);
            // Late-arriving obstruction already sampled during suppress, but
            // not yet visible at the second CDC stage when suppress falls.
            release_both(0); before_events=events; suppress=1; tick(5);
            drive(1); tick(1); suppress=0; tick(P+F+20);
            check(events==before_events,"CDC in-flight suppressed block cannot trigger on exit");
            release_both(0); pair_test(0,1,6*MS,255,2);
            boot(3); pair_test(3,1,6*MS,255,2); // idle HIGH, blocked LOW
            boot(1); pair_test(1,0,25*MS,180,6); // independent mixed polarities
            // Demonstrate the documented boot-obstruction limitation: cannot
            // distinguish an obstructed starting path from its true idle level.
            boot(1); before_events=events;
            check(blocked==0,"boot obstruction is learned as idle (known limit)");
            drive(0); await_event(before_events,P+F+12);
            check(blocked==1,"removing boot obstruction looks like block; reset required");
            boot(0); pair_test(0,0,6*MS,255,2);
            // Startup motion restarts the full stable qualification interval.
            @(negedge clk); #2; rst_n=0; beams=0; tick(3);
            @(negedge clk); #2; rst_n=1; tick(S/2); drive(3); tick(F+4);
            drive(0); start=cycles; tick(S-1); check(!ready,"startup movement restarts stability");
            tick(F+20); check(ready && blocked==0,"startup recovers after stable paths");
            $display("PASS tb_optical_strum scaled checks=%0d cycles=%0d",checks,cycles);
        end
        $finish;
    end
    initial begin #2000000000; $fatal(1,"optical watchdog"); end
endmodule
