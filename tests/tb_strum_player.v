`timescale 1ns/1ps
module tb_strum_player;
    parameter PRODUCTION=0;
    localparam HZ=PRODUCTION?27000000:10000;
    localparam MS=HZ/1000;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0, trigger=0, reverse=0, suppress=0, event_ready=1;
    reg [7:0] velocity=200;
    reg [3:0] gap_ms=4;
    reg [127:0] held_notes=0;
    wire event_valid,event_on,event_off,busy;
    wire [6:0] event_note;
    wire [7:0] event_velocity;
    strum_player #(.CLK_HZ(HZ)) dut(.*);
    integer cycles=0, count=0, checks=0, active [0:127];
    integer log_note [0:511], log_on [0:511], log_v [0:511], log_cycle [0:511];
    integer k;
    reg previous_stall=0;
    reg [17:0] previous_frame=0;
    wire [17:0] frame={event_valid,event_on,event_off,event_note,event_velocity};
    // Scoreboard uses only externally ACCEPTED frames. No DUT internals used.
    always @(posedge clk) begin
        cycles=cycles+1;
        if(!rst_n || suppress) begin
            for(k=0;k<128;k=k+1) active[k]=0;
            previous_stall=0;
        end else begin
            if(previous_stall && frame!==previous_frame)
                $fatal(1,"event changed under backpressure cycle=%0d",cycles);
            if(event_valid && (event_on==event_off)) $fatal(1,"invalid on/off frame");
            if(event_valid && event_ready) begin
                if(event_on) begin
                    if(active[event_note]!=0) $fatal(1,"new on before old off note=%0d",event_note);
                    active[event_note]=active[event_note]+1;
                end else begin
                    if(active[event_note]!=1) $fatal(1,"lost/duplicate off note=%0d",event_note);
                    if(event_velocity!=0) $fatal(1,"off velocity nonzero");
                    active[event_note]=active[event_note]-1;
                end
                log_note[count]=event_note; log_on[count]=event_on;
                log_v[count]=event_velocity; log_cycle[count]=cycles; count=count+1;
            end
            previous_stall=event_valid && !event_ready;
            previous_frame=frame;
        end
    end
    task tick;
        input integer n;
        begin repeat(n) @(posedge clk); #2; end
    endtask
    task check;
        input condition;
        input [511:0] message;
        begin if(condition!==1'b1) $fatal(1,"%0s cycle=%0d count=%0d",message,cycles,count);
            checks=checks+1; end
    endtask
    task command;
        input [127:0] chord;
        input integer backwards, vel, gap;
        begin
            @(negedge clk); #2; held_notes=chord; reverse=backwards;
            velocity=vel; gap_ms=gap; trigger=1;
            @(negedge clk); #2; trigger=0;
        end
    endtask
    task await_count;
        input integer target, limit;
        integer start;
        begin start=cycles;
            while(count<target && cycles-start<limit) tick(1);
            check(count==target,"event count timeout/overshoot");
        end
    endtask
    task await_idle;
        input integer limit;
        integer start,j;
        begin start=cycles;
            while(busy && cycles-start<limit) tick(1);
            check(!busy && !event_valid,"player must return idle");
            for(j=0;j<128;j=j+1) check(active[j]==0,"all accepted ons must have offs");
        end
    endtask
    task expect_event;
        input integer idx, note_number, on_value, vel;
        begin check(log_note[idx]==note_number && log_on[idx]==on_value &&
                    log_v[idx]==vel,"event note/order/velocity"); end
    endtask
    localparam [127:0] TRIAD=(128'b1<<60)|(128'b1<<64)|(128'b1<<67);
    integer base,last_on,j,start;
    initial begin
        tick(4); @(negedge clk); #2; rst_n=1; tick(3);
        if(PRODUCTION) begin
            base=count; command((128'b1<<60)|(128'b1<<64),0,231,2);
            await_count(base+2,2*MS+200); last_on=log_cycle[base+1];
            check(log_cycle[base+1]-log_cycle[base]==2*MS,"27MHz exact 2ms gap");
            while(cycles<last_on+150*MS-1) tick(1);
            check(count==base+2,"27MHz off cannot occur before 150ms hold");
            tick(1); check(count==base+3,"27MHz first off exactly 150ms after final on");
            check(log_cycle[base+2]-last_on==4050000,"production hold cycle count");
            await_idle(20); check(count==base+4,"production all offs");
            $display("PASS tb_strum_player production checks=%0d cycles=%0d",checks,cycles);
        end else begin
            base=count; command(TRIAD,0,211,4);
            held_notes=(128'b1<<10); reverse=1; velocity=1; gap_ms=15;
            await_count(base+3,400);
            expect_event(base,60,1,211); expect_event(base+1,64,1,211); expect_event(base+2,67,1,211);
            check(log_cycle[base+1]-log_cycle[base]==4*MS &&
                  log_cycle[base+2]-log_cycle[base+1]==4*MS,"snapshot gap exact");
            await_idle(2000);
            expect_event(base+3,60,0,0); expect_event(base+4,64,0,0); expect_event(base+5,67,0,0);
            check(log_cycle[base+3]-log_cycle[base+2]==150*MS,"hold starts at last accepted on");
            base=count; command(0,1,160,8); await_idle(2300);
            expect_event(base,72,1,160); expect_event(base+1,67,1,160);
            expect_event(base+2,64,1,160); expect_event(base+3,60,1,160);
            check(count==base+8,"empty MIDI chord fallback count");
            base=count; command((128'b1<<0)|(128'b1<<127),1,88,0); await_idle(2000);
            expect_event(base,127,1,88); expect_event(base+1,0,1,88);
            check(count==base+4,"notes 0/127 and zero gap");
            held_notes=0; for(j=30;j<40;j=j+1) held_notes[j]=1;
            base=count; command(held_notes,0,190,2); await_idle(2200);
            for(j=0;j<6;j=j+1) expect_event(base+j,30+j,1,190);
            check(count==base+12,"large ascending chord capped at six");
            base=count; command(held_notes,1,191,2); await_idle(2200);
            for(j=0;j<6;j=j+1) expect_event(base+j,39-j,1,191);
            check(count==base+12,"large descending chord capped at six");
            // Long initial on backpressure, then blocked off. Frame checker
            // above verifies every payload bit remains stable on every clock.
            base=count; event_ready=0; command(TRIAD,0,155,6); tick(300);
            check(count==base && event_valid && event_on,"stalled on retained");
            event_ready=1; await_count(base+3,300); event_ready=0;
            tick(1600); check(count==base+3 && event_valid && event_off,"stalled off retained");
            tick(100); event_ready=1; await_idle(100);
            check(count==base+6,"backpressure loses no offs");
            // Preempt stalled ON: immutable frame must still be accepted and
            // released, while the pending snapshot is overwritten twice.
            base=count; event_ready=0; command(TRIAD,0,170,10); tick(150);
            command((128'b1<<70),0,90,2); command((128'b1<<80),1,99,4);
            tick(40); check(count==base && event_valid && event_on,"preempt preserves stalled on");
            event_ready=1; await_count(base+2,40);
            expect_event(base,60,1,170); expect_event(base+1,60,0,0);
            await_count(base+3,180); expect_event(base+2,80,1,99);
            await_idle(1700); check(count==base+4,"only latest pending command plays");
            // Interrupt after several accepted ons; triggers arriving during
            // off backpressure may replace pending but must never skip cleanup.
            base=count; command(TRIAD,1,200,2); await_count(base+3,300);
            command((128'b1<<50),0,120,2); event_ready=0; tick(50);
            check(event_valid && event_off,"preemption starts cleanup");
            command((128'b1<<51),0,121,2); command((128'b1<<52),0,122,2);
            tick(80); event_ready=1; await_count(base+6,30);
            expect_event(base+3,67,0,0); expect_event(base+4,64,0,0); expect_event(base+5,60,0,0);
            await_count(base+7,180); expect_event(base+6,52,1,122);
            await_idle(1700); check(count==base+8,"cleanup then latest trigger");
            // Same-edge command and acceptance: the newly accepted old on
            // must be included in cleanup as well.
            base=count; event_ready=0; command(TRIAD,0,187,2); tick(160);
            @(negedge clk); #2; held_notes=128'b1<<90; velocity=123;
            reverse=0; gap_ms=2; trigger=1; event_ready=1;
            @(negedge clk); #2; trigger=0;
            await_idle(1900);
            expect_event(base,60,1,187); expect_event(base+1,60,0,0);
            expect_event(base+2,90,1,123); expect_event(base+3,90,0,0);
            // Suppress cancels stalled off and latest pending. The scoreboard
            // models main's test-mode voice clear; no stale replay on exit.
            base=count; command(TRIAD,0,180,2); await_count(base+3,300);
            command((128'b1<<82),0,181,2); event_ready=0; tick(40);
            @(negedge clk); #2; suppress=1; tick(2);
            check(!event_valid && !busy,"suppress clears stalled event/ledger/pending");
            command((128'b1<<83),0,182,2); tick(10);
            suppress=0; event_ready=1; tick(1900);
            check(count==base+3 && !busy,"suppress exit has no replay");
            base=count; command(128'b1<<84,0,183,2); await_idle(1900);
            expect_event(base,84,1,183); expect_event(base+1,84,0,0);
            // Suppress a never-accepted on, including a coincident trigger.
            base=count; event_ready=0; command(TRIAD,0,199,2); tick(160);
            suppress=1; command(128'b1<<20,0,60,2); tick(2);
            check(!event_valid && !busy,"suppress cancels unaccepted on");
            suppress=0; event_ready=1; tick(1900);
            check(count==base && !busy,"cancelled on never later accepted");
            // Deterministic varied ready pattern exercises repeated transfers.
            base=count; command(TRIAD,1,101,2);
            for(j=0;j<2200;j=j+1) begin
                @(negedge clk); #2; event_ready=((j%7)==0 || (j%11)==0);
            end
            event_ready=1; await_idle(200);
            check(count==base+6,"varied ready pattern complete ledger");
            $display("PASS tb_strum_player scaled checks=%0d events=%0d cycles=%0d",checks,count,cycles);
        end
        $finish;
    end
    initial begin #2000000000; $fatal(1,"player watchdog"); end
endmodule
