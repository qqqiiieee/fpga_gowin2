`timescale 1ns/1ps
// Directed boundary regressions; compile this file with the real RTL.
// Public tops: tb_handoff_selector_ghost, tb_handoff_selector_source,
// tb_handoff_audio_return, tb_handoff_audio_first_tick,
// tb_handoff_ui_hold_1, tb_handoff_ui_hold_0, tb_handoff_ui_hold_200000,
// tb_handoff_diag_exit, tb_handoff_production_return, tb_handoff_boundaries.
// ROMs are relative to the simulation working directory. Define HANDOFF_V014
// only when compiling the old RTL: it omits ports/parameters absent in V014.
// All stimulus changes at falling edges; assertions observe settled NBA results.

module tb_handoff_selector_ghost;
    handoff_selector_case #(.SOURCE_CASE(0)) test();
endmodule
module tb_handoff_selector_source;
    handoff_selector_case #(.SOURCE_CASE(1)) test();
endmodule

module handoff_selector_case #(parameter SOURCE_CASE=0,parameter AUTOFINISH=1)(output reg done);
    initial done=0;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, virtual_enable=0;
    reg [15:0] pressed=0, virtual_keys=0;
    wire [3:0] rows;
    reg [3:0] cols;
    wire note_on,note_off,ghost;
    wire [6:0] note;
    wire [15:0] keys;
    wire [3:0] chosen;
    integer ons=0,offs=0;
    matrix_keypad #(.ROW_CYCLES(12),.DEBOUNCE_FRAMES(3),
        .PERFORMANCE_MODE(1),.SELECT_ON_RELEASE(1),.TWO_BUTTON_SELECT(1)) dut(
        .clk(clk),.rst_n(rst_n),.suppress_select(1'b0),.rows(rows),.cols(cols),
        .virtual_enable(virtual_enable),.virtual_keys(virtual_keys),.velocity(8'd173),
        .note_on(note_on),.note_off(note_off),.note(note),.vel_out(),.timbre_out(),
        .key_state(keys),.ghost_active(ghost),.selected_timbre(chosen));

    // Flood-fill the actual passive switch graph. This is a logical matrix
    // boundary test; board/CST mapping belongs to tb_keypad_physical_map.
    reg [3:0] reached_rows,reached_cols;
    integer pass,r,c;
    always @(*) begin
        reached_rows=0;reached_cols=0;
        for(r=0;r<4;r=r+1) if(rows[r]===1'b0) reached_rows[r]=1;
        for(pass=0;pass<8;pass=pass+1)
            for(r=0;r<4;r=r+1) for(c=0;c<4;c=c+1)
                if(pressed[r*4+c]) begin
                    if(reached_rows[r]) reached_cols[c]=1;
                    if(reached_cols[c]) reached_rows[r]=1;
                end
        cols=~reached_cols;
    end
    always @(posedge clk) begin
        #1;
        if(rst_n) begin
            if(note_on) ons=ons+1;
            if(note_off) offs=offs+1;
            if(note_on && note_off) $fatal(1,"BOUNDARY_FAIL simultaneous note events");
        end
    end
    task cycles;
        input integer n;
        begin repeat(n) @(negedge clk); #2; end
    endtask
    task need;
        input condition;
        input [1023:0] message;
        begin if(condition!==1'b1) begin
            $display("BOUNDARY_COUNTEREXAMPLE selector source_case=%0d time=%0t physical=%h virtual_enable=%b virtual=%h raw=%h keys=%h ghost=%b chosen=%0d ons=%0d offs=%0d: %0s",
                SOURCE_CASE,$time,pressed,virtual_enable,virtual_keys,dut.raw_keys,keys,ghost,chosen,ons,offs,message);
            $fatal(1,"HANDOFF_SELECTOR_FAIL");
        end end
    endtask
    task fresh_selection;
        begin
            @(negedge clk);pressed=16'h2001;
            cycles(240);
            need(keys===16'h2001 && chosen==0,"fresh press must retain old timbre");
            @(negedge clk);pressed=16'h0001;
            cycles(240);
            need(chosen==1,"a fresh clean S14 release must still select exactly once");
            need(ons==(SOURCE_CASE?3:2) && offs==(SOURCE_CASE?2:1),
                "selection cancellation must not reset or duplicate ordinary note events");
            @(negedge clk);pressed=0;
            cycles(240);
            need(keys==0 && offs==(SOURCE_CASE?3:2),"final ordinary note release must survive");
        end
    endtask
    initial begin
        cycles(4);rst_n=1;cycles(240);
        @(negedge clk);pressed=16'h1001;
        cycles(240);
        need(keys===16'h1001 && chosen==0 && ons==1 && offs==0,
            "precondition: S13 candidate and one ordinary held note");
        if(SOURCE_CASE) begin
            @(negedge clk);virtual_enable=1;virtual_keys=0;
            cycles(300);
            need(keys==0 && ons==1 && offs==1,"physical-to-virtual transition must emit the note release");
            need(chosen==0,"physical S13 release synthesized by source change must be cancelled");
            @(negedge clk);virtual_keys=16'h2002;
            cycles(240);
            need(keys===16'h2002 && chosen==0 && ons==2 && offs==1,
                "virtual source must accept a fresh S14 candidate and ordinary note");
            @(negedge clk);pressed=0;virtual_enable=0;
            cycles(300);
            need(keys==0 && ons==2 && offs==2,"virtual-to-physical transition must emit the note release");
            need(chosen==0,"virtual S14 release synthesized by source change must be cancelled");
        end else begin
            @(negedge clk);pressed=16'h3001;
            cycles(240);
            need(ghost && dut.raw_keys===16'h3003 && keys===16'h1001,
                "precondition: real ghost rectangle with only the old S13 candidate confirmed");
            need(ons==1 && offs==0,"ghost must preserve old note and suppress phantom notes");
            @(negedge clk);pressed=16'h1001;
            cycles(240);
            need(!ghost && chosen==0,"removing the added switch must not restore a cancelled candidate");
            @(negedge clk);pressed=16'h0001;
            cycles(240);
            need(chosen==0,"S13 candidate that encountered ghost must not commit on release");
            need(ons==1 && offs==0,"held note must survive selector cancellation");
            @(negedge clk);pressed=0;
            cycles(240);
            need(keys==0 && offs==1,"all-up must release ordinary note and permit a new selector gesture");
        end
        fresh_selection();
        if(SOURCE_CASE)$display("HANDOFF_SELECTOR_SOURCE_TEST_PASS source_cancel/both_directions/note_event_preservation/fresh_selection");
        else $display("HANDOFF_SELECTOR_GHOST_TEST_PASS single_candidate/real_rectangle/latched_cancel/held_note/fresh_selection");
        done=1;if(AUTOFINISH)$finish;
    end
    initial begin #1000000;if(!done)$fatal(1,"HANDOFF_SELECTOR_TIMEOUT");end
endmodule

module tb_handoff_audio_return;
    handoff_audio_case #(.FIRST_TICK(0)) test();
endmodule
module tb_handoff_audio_first_tick;
    handoff_audio_case #(.FIRST_TICK(1)) test();
endmodule

module handoff_audio_case #(parameter FIRST_TICK=0,parameter AUTOFINISH=1)(output reg done);
    initial done=0;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0;
    reg [15:0] virtual_keys=0;
    wire [15:0] keys;
    wire key_on,key_off,ghost;
    wire [6:0] key_note;
    wire [7:0] key_velocity;
    wire [3:0] key_timbre;
    wire owned,mode,clear_audio,sweep,tick;
    wire [3:0] state;
    wire [31:0] test_gate,busy,test_busy;
    wire [5:0] requested;
    wire [4:0] index;
    wire [8:0] gain;
    wire normal_input_ready;
    wire [15:0] pcm;
    wire [1:0] page,cursor,song_id;
    wire ui_start,ui_toggle,ui_restart,guide_active,guide_done;
    wire [5:0] guide_step;
    wire [7:0] guide_progress;
    reg injected_on=0,injected_off=0,hit0=0,hit1=0;
    reg [6:0] injected_note=60;
    wire note_on=key_on || injected_on;
    wire note_off=key_off || injected_off;
    wire [6:0] note=(injected_on || injected_off)?injected_note:key_note;
    integer ons=0,offs=0,nonzero=0;

    matrix_keypad #(.ROW_CYCLES(12),.DEBOUNCE_FRAMES(3),.PERFORMANCE_MODE(1),
        .SELECT_ON_RELEASE(1),.TWO_BUTTON_SELECT(1)) keypad(
        .clk(clk),.rst_n(rst_n),.suppress_select(owned),.rows(),.cols(4'hf),
        .virtual_enable(1'b1),.virtual_keys(virtual_keys),.velocity(8'd173),
        .note_on(key_on),.note_off(key_off),.note(key_note),.vel_out(key_velocity),
        .timbre_out(key_timbre),.key_state(keys),.ghost_active(ghost),.selected_timbre());
    oscillator_test_control #(.HOLD_SAMPLES(2),.MAX_SAMPLES(100000),
        .SWEEP_HALF_SAMPLES(8),.RAMP_DIV(2)) controller(
        .clk(clk),.rst_n(rst_n),.sample_tick(tick),.keys(keys),.ghost(ghost),
        .remote_active(1'b1),.owned(owned),.test_mode(mode),.gate_mask(test_gate),
        .requested_count(requested),.sweep_active(sweep),.sweep_index(index),
        .master_gain(gain),.clear_audio(clear_audio),.state_debug(state)
`ifndef HANDOFF_V014
        ,.normal_input_ready(normal_input_ready)
`endif
    );
    instrument_audio #(.LOWPASS_ENABLE(0),.NUM_VOICES(32)
`ifndef HANDOFF_V014
        ,.TRANSITION_INPUT_ENABLE(1)
`endif
    ) audio(
        .clk(clk),.rst_n(rst_n),.note_on(note_on),.note_off(note_off),.note(note),
        .velocity((injected_on || injected_off)?8'd173:key_velocity),
        .timbre((injected_on || injected_off)?4'd2:key_timbre),
        .slider_volume(8'd160),.slider_pitch(9'sd0),
        .hit0(hit0),.hit1(hit1),.velocity0(8'd173),.velocity1(8'd107),
        .digital_zero_test(1'b0),.filter_enable(1'b0),
        .test_owned(owned),.test_mode(mode),.test_clear(clear_audio),
`ifndef HANDOFF_V014
        .normal_input_ready(normal_input_ready),
`endif
        .test_gate_mask(test_gate),.test_master_gain(gain),
        .hp_bck(),.hp_ws(),.hp_din(),.overrun(),.monitor_tick(tick),
        .monitor_pcm(pcm),.monitor_pitch(),.monitor_busy(busy),.monitor_test_busy(test_busy));
    defparam audio.synth.FILE="src/timbre_soft.hex";
    defparam audio.synth.TEST_FILE="src/test_sine.hex";
    instrument_ui_control #(.HOLD_SAMPLES(4)) ui(
        .clk(clk),.rst_n(rst_n),.sample_tick(tick),.keys(keys),.ghost(ghost),
        .test_owned(owned),.remote_active(1'b1),.page(page),.cursor(cursor),
        .song_id(song_id),.song_start(ui_start),.song_toggle(ui_toggle),.song_restart(ui_restart));
    wire menu_pause=(|keys[15:14]) && keys!=16'h9000 && keys!=16'h3000;
    song_guide #(.EXTERNAL_UI(1),.BEAT_SAMPLES(100000)) guide(
        .clk(clk),.rst_n(rst_n),.sample_tick(tick),.pause(owned || page!=0 || menu_pause),
        .keys(keys),.ghost(ghost),.song_id(song_id),.ui_start(ui_start),
        .ui_toggle(ui_toggle),.ui_restart(ui_restart),.active(guide_active),.done(guide_done),
        .cue_mask(),.next_mask(),.wrong_mask(),.step_index(guide_step),.total_steps(),
        .beat_progress(guide_progress),.target_beats());
    always @(posedge clk) begin
        #1;
        if(rst_n) begin
            if(key_on)ons=ons+1;
            if(key_off)offs=offs+1;
            if(audio.overrun)$fatal(1,"BOUNDARY_FAIL audio scheduler overrun");
            if(state==6)begin
                if(!owned || mode)$fatal(1,"BOUNDARY_FAIL FSM ownership changed during normal fade-in");
                if(page!=0 || ui_start || ui_toggle || ui_restart || guide_step!=0 || guide_progress!=0)
                    $fatal(1,"BOUNDARY_FAIL UI/guide accepted preparation events while owned");
            end
        end
    end
    task cycles;
        input integer n;
        begin repeat(n)@(negedge clk);#2;end
    endtask
    task wait_state;
        input [3:0] wanted;
        integer n;
        begin n=0;while(state!==wanted && n<400000)begin @(negedge clk);n=n+1;end
            #2;if(state!==wanted)$fatal(1,"BOUNDARY_FAIL controller state timeout wanted=%0d actual=%0d",wanted,state);
        end
    endtask
    task need;
        input condition;
        input [1023:0] message;
        begin if(condition!==1'b1)begin
            $display("BOUNDARY_COUNTEREXAMPLE audio first_tick=%0d time=%0t state=%0d owned=%b mode=%b gain=%0d sample_tick=%b keys=%h gate=%h busy=%h kick_busy=%b snare_busy=%b ons=%0d offs=%0d: %0s",
                FIRST_TICK,$time,state,owned,mode,gain,tick,keys,audio.gate,busy,audio.kick_busy,audio.snare_busy,ons,offs,message);
            $fatal(1,"HANDOFF_AUDIO_RETURN_FAIL");
        end end
    endtask
    task inject;
        input on_event,off_event,drums;
        begin
            @(negedge clk);injected_on=on_event;injected_off=off_event;hit0=drums;hit1=drums;
            @(negedge clk);injected_on=0;injected_off=0;hit0=0;hit1=0;#2;
        end
    endtask
    initial begin
        cycles(4);rst_n=1;cycles(300);
        @(negedge clk);virtual_keys=16'h5000;
        wait_state(3);
        @(negedge clk);virtual_keys=0;cycles(300);
        need(owned && mode && audio.gate==0,"precondition: active test owns audio and normal allocator is empty");
        @(negedge clk);virtual_keys=16'h8000;
        wait_state(5);
        need(gain==0 && owned && !mode,"exit must wait for release at zero gain");
        @(negedge clk);virtual_keys=0;
        wait_state(6);
        need(owned && !mode && gain==0 && !clear_audio,"precondition: zero-gain normal fade-in before its first tick");
        if(FIRST_TICK)begin
            while(!tick)@(negedge clk);
            need(state==6 && gain==0,"first sample_tick must see old gain zero");
            injected_on=1;hit0=1;hit1=1;
            $display("BOUNDARY_FIRST_TICK_STIMULUS time=%0t state=%0d gain=%0d tick=%b note_on=1 hit0=1 hit1=1",$time,state,gain,tick);
            @(negedge clk);injected_on=0;hit0=0;hit1=0;#2;
            need(audio.gate!=0,"first fade-in sample_tick must accept the one-clock note_on");
            need(audio.kick_busy && audio.snare_busy,"first fade-in sample_tick must accept both one-clock drum hits");
            need(owned && state==6,"preparation must not release ownership early");
            inject(0,1,0);
            need(audio.gate==0,"note_off during preparation must also be accepted");
            injected_note=64;
            inject(1,0,1);
            cycles(600);
            need(audio.gate!=0 && audio.kick_busy && audio.snare_busy,"ordinary-clock events must remain cached until sampling");
        end else begin
            cycles(1200);
            need(state==6 && owned && gain>0,"precondition: later fade-in window still owns audio");
            @(negedge clk);virtual_keys=1;
            cycles(300);
            need(keys==1 && ons==1 && offs==0,"precondition: real scan/debounce emitted exactly one note_on");
            need(audio.gate!=0,"debounced note_on during fade-in must be allocated rather than discarded");
            @(negedge clk);virtual_keys=0;
            cycles(300);
            need(audio.gate==0 && offs==1,"debounced note_off during fade-in must clear its gate");
            @(negedge clk);virtual_keys=1;
            cycles(300);
            need(audio.gate!=0 && ons==2,"a second preparation press must also be accepted");
        end
        wait_state(0);
        need(!owned && !mode && gain==256 && audio.gate!=0,"prepared held note must survive ownership return");
        repeat(1200)begin cycles(288);if(pcm!=0)nonzero=nonzero+1;end
        need(nonzero>100,"held prepared note must actually produce PCM after return");
        if(FIRST_TICK)begin inject(0,1,0);cycles(4);need(audio.gate==0,"injected held note must release after return");end
        else begin
            need(ons==2 && offs==1,"ownership return must not duplicate or re-emit an accepted note_on");
            @(negedge clk);virtual_keys=0;cycles(300);
            need(audio.gate==0 && offs==2,"ordinary note release must work after return");
        end
        if(FIRST_TICK)$display("HANDOFF_AUDIO_FIRST_TICK_TEST_PASS zero_gain_edge/note_on_off/drum_hits/ownership/UI_guide/PCM");
        else $display("HANDOFF_AUDIO_RETURN_TEST_PASS scan_debounce/prepared_on_off/held_note/ownership/UI_guide/PCM");
        done=1;if(AUTOFINISH)$finish;
    end
    initial begin #15000000;if(!done)$fatal(1,"HANDOFF_AUDIO_TIMEOUT");end
endmodule

module tb_handoff_ui_hold_1;
    handoff_ui_hold_case #(.HOLD(1)) test();
endmodule
module tb_handoff_ui_hold_0;
    handoff_ui_hold_case #(.HOLD(0)) test();
endmodule
module tb_handoff_ui_hold_200000;
    handoff_ui_hold_case #(.HOLD(200000)) test();
endmodule
module handoff_ui_hold_case #(parameter HOLD=1,parameter AUTOFINISH=1)(output reg done);
    initial done=0;
    localparam LIMIT=HOLD<1?1:HOLD;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0,sample_tick=0;
    reg [15:0] keys=0;
    wire [1:0] page,cursor,song_id;
    wire start,toggle,restart;
    instrument_ui_control #(.HOLD_SAMPLES(HOLD)) dut(
        .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),.keys(keys),.ghost(1'b0),
        .test_owned(1'b0),.remote_active(1'b0),.page(page),.cursor(cursor),.song_id(song_id),
        .song_start(start),.song_toggle(toggle),.song_restart(restart));
    task step;
        input [15:0] value;
        input tick_value;
        begin @(negedge clk);keys=value;sample_tick=tick_value;@(posedge clk);#2;end
    endtask
    task need;
        input condition;
        input [767:0] message;
        begin if(condition!==1'b1)begin
            $display("BOUNDARY_COUNTEREXAMPLE UI hold=%0d limit=%0d time=%0t held=%0d long=%b page=%0d start=%b toggle=%b restart=%b: %0s",
                HOLD,LIMIT,$time,dut.held_samples,dut.long_press,page,start,toggle,restart,message);
            $fatal(1,"HANDOFF_UI_HOLD_FAIL");
        end end
    endtask
    integer n;
    initial begin
        step(0,0);step(0,0);rst_n=1;step(0,0);step(0,0);
        step(16'h8000,0);
        for(n=0;n<LIMIT-1;n=n+1)step(16'h8000,1);
        need(!start && !toggle && !restart,"holding must not emit any command before release");
        step(0,0);
        need(toggle && !restart && !start,"LIMIT-1 counted ticks must remain a short press");
        step(0,0);need(!toggle && !restart,"short command must be one clock wide");
        step(16'h8000,0);
        for(n=0;n<LIMIT;n=n+1)step(16'h8000,1);
        need(!start && !toggle && !restart,"long press also commits only on release");
        step(0,0);
        need(restart && !toggle && !start,"LIMIT counted ticks must produce exactly one restart, including zero clamp");
        step(0,0);need(!toggle && !restart,"long command must be one clock wide");
        if(HOLD==1)$display("HANDOFF_UI_HOLD_1_TEST_PASS normalized=%0d exact_threshold/release_commit/one_clock_pulse",LIMIT);
        else if(HOLD==0)$display("HANDOFF_UI_HOLD_0_TEST_PASS normalized=%0d exact_threshold/release_commit/one_clock_pulse",LIMIT);
        else $display("HANDOFF_UI_HOLD_200000_TEST_PASS normalized=%0d exact_threshold/release_commit/one_clock_pulse",LIMIT);
        done=1;if(AUTOFINISH)$finish;
    end
    initial begin #10000000;if(!done)$fatal(1,"HANDOFF_UI_HOLD_TIMEOUT");end
endmodule

module tb_handoff_diag_exit;
    handoff_diag_case test();
endmodule
module handoff_diag_case #(parameter AUTOFINISH=1)(output reg done);
    initial done=0;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0,sample_tick=0,ghost=0;
    reg [15:0] keys=0;
    wire [1:0] page,cursor,song_id;
    wire start,toggle,restart;
    instrument_ui_control #(.HOLD_SAMPLES(3)) dut(
        .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),.keys(keys),.ghost(ghost),
        .test_owned(1'b0),.remote_active(1'b0),.page(page),.cursor(cursor),.song_id(song_id),
        .song_start(start),.song_toggle(toggle),.song_restart(restart));
    task step;
        input [15:0] value;
        input tick_value;
        begin @(negedge clk);keys=value;sample_tick=tick_value;@(posedge clk);#2;end
    endtask
    task need;
        input condition;
        input [767:0] message;
        begin if(condition!==1'b1)begin
            $display("BOUNDARY_COUNTEREXAMPLE diagnostic time=%0t page=%0d cursor=%0d keys=%h ghost=%b start=%b toggle=%b restart=%b: %0s",
                $time,page,cursor,keys,ghost,start,toggle,restart,message);
            $fatal(1,"HANDOFF_DIAG_EXIT_FAIL");
        end end
    endtask
    task enter_diag;
        integer p;
        begin for(p=0;p<3;p=p+1)begin step(16'h4000,0);step(0,0);step(0,0);end
            need(page==3,"three S15 releases must enter diagnostic page");
        end
    endtask
    initial begin
        step(0,0);step(0,0);rst_n=1;step(0,0);step(0,0);
        enter_diag();step(16'h8000,0);step(0,0);
        need(page==0 && cursor==0 && !start && !toggle && !restart,
            "diagnostic short S16 must return to live without a song command");
        step(0,0);enter_diag();step(16'h8000,0);
        repeat(3)step(16'h8000,1);step(0,0);
        need(page==0 && cursor==0 && !start && !toggle && !restart,
            "diagnostic long S16 must also return without a song command");
        step(0,0);enter_diag();step(16'hc000,0);step(0,0);
        need(page==3,"diagnostic exit must reject multi-key gestures");
        step(16'h8000,0);ghost=1;step(16'h8000,1);ghost=0;step(0,0);
        need(page==3,"ghost must cancel diagnostic exit candidate");
        step(16'h8000,0);step(0,0);
        need(page==0 && !start && !toggle && !restart,"fresh clean diagnostic exit must recover after cancellation");
        $display("HANDOFF_DIAG_EXIT_TEST_PASS short/long/no_song_side_effect/chord_cancel/ghost_cancel/recovery");
        done=1;if(AUTOFINISH)$finish;
    end
    initial begin #1000000;if(!done)$fatal(1,"HANDOFF_DIAG_EXIT_TIMEOUT");end
endmodule

module tb_handoff_production_return;
    handoff_production_case test();
endmodule
module handoff_production_case #(parameter AUTOFINISH=1)(output reg done);
    initial done=0;
    reg clk=0;
    always #5 clk=~clk;
    reg [15:0] pressed=0;
    wire [3:0] rows,cols;
    tri1 scl,sda;
    wire tick,owned,mode;
    wire [15:0] pcm,keys;
    wire [7:0] flags;
    integer ons=0,offs=0,nonzero=0;
    genvar c;
    generate for(c=0;c<4;c=c+1)begin:physical_columns
        // Stimulus here never forms a rectangle; passive ghost paths are
        // independently exercised by handoff_selector_case's flood-fill model.
        assign cols[c]=!(((rows[0]===1'b0)&&pressed[c]) ||
            ((rows[1]===1'b0)&&pressed[c+4]) || ((rows[2]===1'b0)&&pressed[c+8]) ||
            ((rows[3]===1'b0)&&pressed[c+12]));
    end endgenerate
    instrument_audio_top #(.LOWPASS_ENABLE(0),.TEST_HOLD_SAMPLES(2),
        .TEST_MAX_SAMPLES(100000),.TEST_SWEEP_HALF_SAMPLES(8),.TEST_RAMP_DIV(2)) dut(
        .clk(clk),.matrix_rows(rows),.matrix_cols(cols),.adc_scl(scl),.adc_sda(sda),
        .uart_rx(1'b1),.uart_tx(),.hp_bck(),.hp_ws(),.hp_din(),.pa_en(),
        .amp_bck(),.amp_lrc(),.amp_din(),.timbre_led_n(),.monitor_rst_n(),
        .monitor_tick(tick),.monitor_pcm(pcm),.monitor_keys(keys),.monitor_timbre(),
        .monitor_volume(),.monitor_pitch(),.monitor_busy(),.monitor_flags(flags),
        .monitor_adc(),.monitor_test_owned(owned),.monitor_test_mode(mode),
        .monitor_test_gate(),.monitor_test_busy(),.monitor_test_requested(),
        .monitor_test_sweep(),.monitor_test_index());
    defparam dut.input_hub.u_keypad.ROW_CYCLES=12;
    defparam dut.input_hub.u_keypad.DEBOUNCE_FRAMES=3;
    defparam dut.audio.synth.FILE="src/timbre_soft.hex";
    defparam dut.audio.synth.TEST_FILE="src/test_sine.hex";
    always @(posedge clk)begin
        #1;
        if(dut.rst_n)begin
            if(dut.note_on)ons=ons+1;
            if(dut.note_off)offs=offs+1;
            if(flags[7])$fatal(1,"BOUNDARY_FAIL production audio overrun");
            if(dut.test_state==6 && (!owned || mode))
                $fatal(1,"BOUNDARY_FAIL production fade-in lost ownership");
        end
    end
    task cycles;
        input integer n;
        begin repeat(n)@(negedge clk);#2;end
    endtask
    task wait_state;
        input [3:0] wanted;
        integer n;
        begin n=0;while(dut.test_state!==wanted && n<400000)begin @(negedge clk);n=n+1;end
            #2;if(dut.test_state!==wanted)$fatal(1,"BOUNDARY_FAIL production state timeout");
        end
    endtask
    task need;
        input condition;
        input [1023:0] message;
        begin if(condition!==1'b1)begin
            $display("BOUNDARY_COUNTEREXAMPLE production time=%0t state=%0d owned=%b mode=%b gain=%0d keys=%h gate=%h ons=%0d offs=%0d: %0s",
                $time,dut.test_state,owned,mode,dut.test_gain,keys,dut.audio.gate,ons,offs,message);
            $fatal(1,"HANDOFF_PRODUCTION_RETURN_FAIL");
        end end
    endtask
    initial begin
        cycles(600);pressed=16'h5000;wait_state(3);
        @(negedge clk);pressed=0;cycles(300);
        need(owned && mode && dut.audio.gate==0,"production active test must have no normal allocation");
        @(negedge clk);pressed=16'h8000;wait_state(5);
        @(negedge clk);pressed=0;wait_state(6);
        cycles(1200);
        @(negedge clk);pressed=1;cycles(300);
        need(keys==1 && ons==1 && offs==0,"physical scanner must emit exactly one preparation note");
        need(owned && dut.audio.gate!=0,"production FSM-to-audio readiness wiring must accept preparation note_on");
        @(negedge clk);pressed=0;cycles(300);
        need(dut.audio.gate==0 && offs==1,"production wiring must accept preparation note_off");
        @(negedge clk);pressed=1;cycles(300);
        need(owned && dut.audio.gate!=0 && ons==2,"production re-press must prepare another held note");
        wait_state(0);
        need(!owned && !mode && dut.test_gain==256 && dut.audio.gate!=0,"production held note must survive normal return");
        repeat(1200)begin cycles(288);if(pcm!=0)nonzero=nonzero+1;end
        need(nonzero>100 && ons==2 && offs==1,"production held note must render PCM without duplicate events");
        @(negedge clk);pressed=0;cycles(300);
        need(dut.audio.gate==0 && offs==2,"production note must release after return");
        $display("HANDOFF_PRODUCTION_RETURN_TEST_PASS physical_scan/production_readiness_wiring/prepared_on_off/held_PCM/ownership");
        done=1;if(AUTOFINISH)$finish;
    end
    initial begin #15000000;if(!done)$fatal(1,"HANDOFF_PRODUCTION_TIMEOUT");end
endmodule

// The portable runner's default boundaries group elaborates this aggregate.
// Per-top runs remain useful for preserving every independent V014 failure.
module tb_handoff_boundaries;
    wire [8:0] done;
    handoff_selector_case #(.SOURCE_CASE(0),.AUTOFINISH(0)) ghost_case(done[0]);
    handoff_selector_case #(.SOURCE_CASE(1),.AUTOFINISH(0)) source_case(done[1]);
    handoff_audio_case #(.FIRST_TICK(0),.AUTOFINISH(0)) audio_case(done[2]);
    handoff_audio_case #(.FIRST_TICK(1),.AUTOFINISH(0)) first_tick_case(done[3]);
    handoff_ui_hold_case #(.HOLD(1),.AUTOFINISH(0)) hold_one(done[4]);
    handoff_ui_hold_case #(.HOLD(0),.AUTOFINISH(0)) hold_zero(done[5]);
    handoff_ui_hold_case #(.HOLD(200000),.AUTOFINISH(0)) hold_large(done[6]);
    handoff_diag_case #(.AUTOFINISH(0)) diag_case(done[7]);
    handoff_production_case #(.AUTOFINISH(0)) production_case(done[8]);
    initial begin wait(&done);#2;$display("HANDOFF_BOUNDARIES_TEST_PASS all_nine_cases");$finish;end
    initial begin #16000000;$fatal(1,"HANDOFF_BOUNDARIES_TIMEOUT");end
endmodule
