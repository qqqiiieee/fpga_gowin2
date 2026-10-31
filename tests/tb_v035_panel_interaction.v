`timescale 1ns/1ps
// Menu + original test controller connected using the agreed top-level adapter.
// This is NOT a full audio/top substitute: no waveform, DAC, or display claim.
module tb_v035_panel_interaction;
    localparam integer DB=3, HOLD=64, SETTLE=DB+10;
    reg clk=0,rst_n=0;
    always #5 clk=~clk;
    reg [1:0] divider=0;
    always @(negedge clk)divider=divider+1'b1;
    wire tick=divider==0;
    reg [3:0] keys_n=15;
    wire [3:0] down;
    wire [1:0] page,song,cursor;
    wire song_start,song_toggle,song_restart,timbre_cycle,mode_cycle,key_pause;
    wire test_toggle,count_cycle,sweep_toggle,full;
    wire owned,mode,sweep,clear,normal_ready;
    wire [31:0] gates;
    wire [5:0] requested;
    wire [4:0] index;
    wire [8:0] gain;
    wire [3:0] state;
    // The menu registers its pulse from pre-edge ownership. Capture that owner
    // on the same edge, then discard commands that became stale at handover.
    reg event_owned=0;
    always @(posedge clk or negedge rst_n)
        if(!rst_n)event_owned<=0;else event_owned<=owned;
    wire enter=test_toggle&&!event_owned&&!owned;
    wire exit_test=test_toggle&&event_owned&&owned;
    wire count_valid=owned&&(count_cycle||full||(sweep_toggle&&sweep));
    reg [5:0] next_count;
    always @*begin
        if(full || (sweep_toggle&&sweep))next_count=32;
        else case(requested)
            1:next_count=4;4:next_count=8;8:next_count=16;16:next_count=32;
            default:next_count=1;
        endcase
    end
    four_button_display_control #(.DEBOUNCE_CYCLES(DB),.LONG_PRESS_CYCLES(HOLD)) menu(
        .clk(clk),.rst_n(rst_n),.keys_n(keys_n),.guide_done(1'b0),.test_owned(owned),
        .page(page),.song_id(song),.cursor(cursor),.song_start(song_start),
        .song_toggle(song_toggle),.song_restart(song_restart),.key_pause(key_pause),
        .buttons_down(down),.phone_set_valid(1'b0),.phone_param(8'd0),.phone_value(8'd0),
        .timbre_cycle(timbre_cycle),.mode_cycle(mode_cycle),.test_toggle(test_toggle),
        .test_count_cycle(count_cycle),.test_sweep_toggle(sweep_toggle),.test_full(full));
    oscillator_test_control #(.HOLD_SAMPLES(999),.MAX_SAMPLES(4093),
        .SWEEP_HALF_SAMPLES(19),.RAMP_DIV(1),.EXTERNAL_UI_ENABLE(1)) engine(
        .clk(clk),.rst_n(rst_n),.sample_tick(tick),.keys(16'd0),.ghost(1'b0),
        .remote_active(1'b0),.owned(owned),.test_mode(mode),.gate_mask(gates),
        .requested_count(requested),.sweep_active(sweep),.sweep_index(index),
        .master_gain(gain),.clear_audio(clear),.state_debug(state),
        .normal_input_ready(normal_ready),.external_enter(enter),.external_exit(exit_test),
        .external_count_valid(count_valid),.external_count(next_count),
        .external_sweep_start(sweep_toggle&&!sweep));
    integer starts=0,restarts=0,toggles=0,test_events=0,count_events=0,sweep_events=0,full_events=0;
    integer checks=0,i,old_test_events,old_restarts;
    reg [3:0] saved_ui;
    wire handover_repro_done,handover_fixed_done,handover_slow_done;
    // Negative control: prove the old adapter really re-enters at the boundary.
    // Positive controls: identical real-controller stimulus with owner capture,
    // including a different debounce length and divided gain-ramp sample rate.
    v035_panel_handover_case #(.FIX_ROUTING(0),.DB(1),.DIV(1)) handover_repro(
        .clk(clk),.done(handover_repro_done));
    v035_panel_handover_case #(.FIX_ROUTING(1),.DB(1),.DIV(1)) handover_fixed(
        .clk(clk),.done(handover_fixed_done));
    v035_panel_handover_case #(.FIX_ROUTING(1),.DB(5),.DIV(3)) handover_slow(
        .clk(clk),.done(handover_slow_done));
    task check(input condition,input [1023:0] message);
        begin checks=checks+1;if(condition!==1'b1)
            $fatal(1,"%0s state=%0d gain=%0d req=%0d",message,state,gain,requested);end
    endtask
    always @(posedge clk)begin
        #1;
        if(rst_n)begin
            if(owned && (song_start||song_toggle||song_restart||timbre_cycle||mode_cycle))
                $fatal(1,"song/timbre/mode event leaked during ownership");
            if(song_start)starts=starts+1;
            if(song_restart)restarts=restarts+1;
            if(song_toggle)toggles=toggles+1;
            if(test_toggle)test_events=test_events+1;
            if(count_cycle)count_events=count_events+1;
            if(sweep_toggle)sweep_events=sweep_events+1;
            if(full)full_events=full_events+1;
        end
    end
    task cycles(input integer n);
        repeat(n)begin @(posedge clk);#2;end
    endtask
    task level(input [3:0] mask,input integer n);
        begin @(negedge clk);keys_n=~mask;cycles(n);end
    endtask
    task click(input integer key,input integer duration);
        begin level(1<<key,duration);level(0,2*SETTLE);end
    endtask
    task wait_phase(input [3:0] wanted,input integer limit);
        integer age;
        begin
            age=0;while(state!=wanted && age<limit)begin cycles(1);age=age+1;end
            check(state==wanted,"bounded state transition");
        end
    endtask
    initial begin
        cycles(4);@(negedge clk);rst_n=1;cycles(2*SETTLE);
        click(1,SETTLE);click(0,SETTLE);click(3,SETTLE);
        check(starts==1 && page==1 && song==1,"normal short functions before diagnostic");
        saved_ui={page,song};old_restarts=restarts;old_test_events=test_events;
        level(4,HOLD*3);check(!owned && test_events==old_test_events,"long3 waits for debounced release");
        level(0,2*SETTLE);
        check(owned && state==1 && !mode,"panel enters original preparation without old chord");
        check(restarts==old_restarts && test_events==old_test_events+1,"entry no short3 restart");
        // Controls pressed during the fade are not queued into ACTIVE.
        click(0,SETTLE);click(3,SETTLE);wait_phase(3,3000);cycles(2*SETTLE);
        check(gain==256 && mode && requested==32 && gates==32'hffffffff,"all32 default after safe fade");
        for(i=0;i<5;i=i+1)begin
            click(0,SETTLE);
            check(requested==(i==0?1:(i==1?4:(i==2?8:(i==3?16:32)))),"button count cycle 32/1/4/8/16/32");
        end
        click(1,SETTLE);check(sweep&&requested==32,"button2 starts sweep");
        click(1,SETTLE);check(!sweep&&requested==32&&gates==32'hffffffff,"button2 stops sweep via full32");
        click(1,SETTLE);check(sweep,"sweep can restart");
        click(3,SETTLE);check(!sweep&&requested==32&&gates==32'hffffffff,"button4 all32 cancels sweep");
        check({page,song}==saved_ui && starts==1 && toggles==0 && restarts==old_restarts,
              "diagnostic count/sweep/full never touches teaching state");
        old_test_events=test_events;click(2,SETTLE);
        check(state==4&&!sweep&&test_events==old_test_events+1,"short3 requests original safe exit");
        wait_phase(0,3000);cycles(2*SETTLE);
        check(!owned&&!mode&&gain==256&&requested==0,"normal output restored");
        check({page,song}==saved_ui,"mode exit preserves page/song selection");
        click(2,SETTLE);check(restarts==old_restarts+1,"normal short3 restarts again after exit");
        // Long3 in ACTIVE also exits exactly once and may not re-enter on release.
        click(2,HOLD*2);wait_phase(3,3000);cycles(2*SETTLE);
        old_test_events=test_events;click(2,HOLD*4);
        check(state==4&&test_events==old_test_events+1,"owned long3 one exit event");
        wait_phase(0,3000);cycles(HOLD*2);
        check(!owned&&test_events==old_test_events+1,"long exit cannot re-enter after ownership edge");
        // A quick second released3 during preparation is an abort, never a song restart.
        click(2,HOLD*2);check(state==1,"new entry for abort");
        old_restarts=restarts;click(2,SETTLE);
        check(state==4&&!mode&&restarts==old_restarts,"panel can abort preparation");
        wait_phase(0,3000);cycles(2*SETTLE);
        // No input at all: original ACTIVE timeout plus fades returns NORMAL.
        click(2,HOLD*2);wait_phase(3,3000);
        wait_phase(4,17000);wait_phase(0,3000);cycles(2*SETTLE);
        check(!owned&&!mode&&gain==256,"timeout bounded after four-button entry");
        check(count_events>=5&&sweep_events==3&&full_events>=1,"meaningful complete control coverage");
        check(handover_repro_done&&handover_fixed_done&&handover_slow_done,
              "old-routing reproducer and both corrected handover cases complete");
        $display("V035_PANEL_INTERACTION_PASS checks=%0d entry_exit=%0d counts=%0d sweep=%0d full=%0d no_song_leak=1",
                 checks,test_events,count_events,sweep_events,full_events);
        $finish;
    end
    initial begin #1000000;$fatal(1,"panel interaction watchdog");end
endmodule

// Targeted ownership-boundary reproducer and regression, with no forced state,
// no hierarchy writes and no synthetic test_toggle. All commands originate in
// real synchronized/debounced physical button input; the timeout and recovery
// ramps are those of the production oscillator_test_control instance.
module v035_panel_handover_case #(
    parameter integer FIX_ROUTING=1, DB=1, DIV=1
)(input wire clk,output reg done=0);
    localparam integer HOLD=64, SETTLE=DB+9, RELEASE_LATENCY=DB+3;
    reg rst_n=0;
    reg [3:0] keys_n=15;
    wire [3:0] down,state;
    wire owned,mode,sweep,clear,ready;
    wire [31:0] gates;
    wire [5:0] requested;
    wire [4:0] index;
    wire [8:0] gain;
    wire toggle_event,count_event,sweep_event,full_event;
    wire song_start,song_toggle,song_restart,timbre_event,mode_event;
    reg event_owned=0;
    always @(posedge clk or negedge rst_n)
        if(!rst_n)event_owned<=0;else event_owned<=owned;
    wire enter=toggle_event&&!owned&&(!FIX_ROUTING||!event_owned);
    wire exit_test=toggle_event&&owned&&(!FIX_ROUTING||event_owned);
    integer checks=0,toggle_events=0,restarts=0,old_events,age;
    four_button_display_control #(.DEBOUNCE_CYCLES(DB),.LONG_PRESS_CYCLES(HOLD)) menu(
        .clk(clk),.rst_n(rst_n),.keys_n(keys_n),.guide_done(1'b0),.test_owned(owned),
        .phone_set_valid(1'b0),.phone_param(8'd0),.phone_value(8'd0),.buttons_down(down),
        .song_start(song_start),.song_toggle(song_toggle),.song_restart(song_restart),
        .timbre_cycle(timbre_event),.mode_cycle(mode_event),.test_toggle(toggle_event),
        .test_count_cycle(count_event),.test_sweep_toggle(sweep_event),.test_full(full_event));
    oscillator_test_control #(.HOLD_SAMPLES(999),.MAX_SAMPLES(1),
        .SWEEP_HALF_SAMPLES(3),.RAMP_DIV(DIV),.EXTERNAL_UI_ENABLE(1)) engine(
        .clk(clk),.rst_n(rst_n),.sample_tick(1'b1),.keys(16'd0),.ghost(1'b0),
        .remote_active(1'b0),.owned(owned),.test_mode(mode),.gate_mask(gates),
        .requested_count(requested),.sweep_active(sweep),.sweep_index(index),
        .master_gain(gain),.clear_audio(clear),.state_debug(state),.normal_input_ready(ready),
        .external_enter(enter),.external_exit(exit_test),.external_count_valid(1'b0),
        .external_count(6'd0),.external_sweep_start(1'b0));
    task check(input condition,input [1023:0] message);
        begin checks=checks+1;if(condition!==1'b1)
            $fatal(1,"%0s fixed=%0d DB=%0d DIV=%0d state=%0d gain=%0d event=%b captured/current=%b/%b",
                   message,FIX_ROUTING,DB,DIV,state,gain,toggle_event,event_owned,owned);end
    endtask
    task cycles(input integer n);
        repeat(n)begin @(posedge clk);#2;end
    endtask
    task click3(input integer duration);
        begin
            @(negedge clk);keys_n=4'hb;cycles(duration);
            @(negedge clk);keys_n=15;cycles(2*SETTLE);
        end
    endtask
    task wait_phase(input [3:0] wanted,input integer limit);
        begin
            age=0;while(state!=wanted&&age<limit)begin cycles(1);age=age+1;end
            check(state==wanted,"bounded real state transition");
        end
    endtask
    always @(posedge clk)begin
        #1;
        if(rst_n)begin
            if(toggle_event)toggle_events=toggle_events+1;
            if(song_restart)restarts=restarts+1;
            if(song_start||song_toggle||timbre_event||mode_event||count_event||sweep_event||full_event)
                $fatal(1,"unexpected unrelated command in handover fixture");
        end
    end
    initial begin
        cycles(4);@(negedge clk);rst_n=1;cycles(2*SETTLE);
        click3(HOLD+SETTLE);
        check(state==1&&owned&&!mode&&toggle_events==1&&restarts==0,
              "real normal long3 entered without short restart");
        // MAX_SAMPLES=1 creates a genuine timed exit, NOT a testbench reset.
        // At gain240 exactly 16*DIV enabled samples remain until owned falls.
        wait(state==6&&gain==240);
        @(negedge clk);keys_n=4'hb;
        cycles(16*DIV-RELEASE_LATENCY);
        @(negedge clk);keys_n=15;
        cycles(RELEASE_LATENCY);
        check(state==0&&!owned&&gain==256&&!mode&&down==0,
              "physical release lands exactly on NORMAL_IN to NORMAL");
        check(toggle_event&&event_owned&&toggle_events==2&&restarts==0,
              "menu emitted one owned-domain exit on real boundary");
        if(!FIX_ROUTING)begin
            check(enter&&!exit_test,"negative control: current-owned decoder misclassifies exit as enter");
            cycles(1);
            check(state==1&&owned,"negative control must reproduce unwanted re-entry");
            $display("V035_PANEL_HANDOVER_REPRO_PASS fixed=0 DB=%0d DIV=%0d checks=%0d old_reentered=1",
                     DB,DIV,checks);
        end else begin
            check(!enter&&!exit_test,"captured/current mismatch drops stale exit");
            cycles(2*SETTLE);
            check(state==0&&!owned&&!mode&&gain==256&&toggle_events==2,
                  "corrected routing stays NORMAL after stale event");
            // Capturing the owner must not suppress legitimate subsequent UI.
            click3(SETTLE);
            check(restarts==1&&toggle_events==2&&!owned,"new normal short3 still restarts only");
            click3(HOLD+SETTLE);
            check(state==1&&owned&&toggle_events==3,"new normal long3 can enter again");
            old_events=toggle_events;click3(SETTLE);
            check(state==4&&owned&&!mode&&toggle_events==old_events+1&&restarts==1,
                  "legitimate owned short3 abort remains an exit");
            wait_phase(0,1200*DIV);cycles(2*SETTLE);
            check(!owned&&!mode&&gain==256&&toggle_events==4,
                  "abort recovery stays normal without phantom re-entry");
            $display("V035_PANEL_HANDOVER_FIXED_PASS fixed=1 DB=%0d DIV=%0d checks=%0d stale_dropped=1 normal_short3=1 new_entry_exit=1",
                     DB,DIV,checks);
        end
        done=1;
    end
endmodule
