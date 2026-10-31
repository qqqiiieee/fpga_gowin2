`timescale 1ns/1ps
module tb_guide_play_modes;
 wire demo_valid, demo_note_retrigger;
 wire [6:0] demo_note;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, running=0, suspended=0, restart=0, score_ready=1;
    reg [1:0] mode=0;
    reg [6:0] expected_note=60, midi_note=60;
    reg expected_valid=0, midi_note_on=0;
    reg [5:0] step_index=0;
    wire practice_hold;
    wire [31:0] demo_gate, demo_retrigger;
    wire [7:0] demo_velocity;
    integer checks=0, n;
    guide_play_modes dut(.*);

    task check;
        input condition;
        input [8*140-1:0] message;
        begin
            checks=checks+1;
            if (condition !== 1) $fatal(1,"GUIDE_MODES_FAIL: %0s",message);
        end
    endtask
    // Return on negedge; input changes then have half a clock to settle.
    task tick;
        begin @(posedge clk); #1; @(negedge clk); end
    endtask
    task quiet;
        begin midi_note_on=0; tick; end
    endtask
    task key;
        input [6:0] note;
        begin midi_note=note; midi_note_on=1; tick; midi_note_on=0; end
    endtask
    task waiting;
        begin #1; check(practice_hold,"practice must wait");
            check(demo_gate==0 && demo_retrigger==0,"practice never synthesizes"); end
    endtask
    task released;
        begin #1; check(!practice_hold,"accepted note can run its duration"); end
    endtask
    task demo;
        input [6:0] note;
        input trigger;
        reg [31:0] want;
        begin
            want=(note>=41 && note<=72)?(32'h1 << (note-41)):0;
            #1;
            check(demo_gate==want,"absolute MIDI pitch to gate mapping / off");
            check(demo_retrigger==(trigger?want:0),"exact retrigger pulse");
            check(!practice_hold,"demo never freezes timeline");
        end
    endtask
    initial begin
        #1; tick; rst_n=1; tick;
        running=1; expected_valid=1;
        for(n=0;n<4;n=n+1) begin key(60); tick;
            check(!practice_hold && demo_gate==0 && demo_retrigger==0,
                  "fixed BPM ignores correct MIDI without auto synthesis"); end

        // A key already high at entry is not accepted, nor a later held level.
        mode=2; midi_note_on=1; tick; tick; waiting;
        repeat(5) begin tick; waiting; end
        quiet; key(61); waiting; quiet; key(60); released;
        repeat(6) begin quiet; released; end

        // An extra correct pulse before the NEXT same-note step is never queued.
        key(60); quiet; step_index=1; #1; waiting; tick; waiting;
        repeat(3) begin quiet; waiting; end
        key(60); released;
        // A pulse spanning a boundary is discarded until it goes low again.
        midi_note_on=1; step_index=2; tick; waiting;
        repeat(3) begin tick; waiting; end
        quiet; key(60); released;

        // Rest/count-in is free; early playing during rest is not banked.
        expected_valid=0; tick; check(!practice_hold,"rest runs"); key(62);
        expected_note=62; step_index=3; expected_valid=1; tick; waiting;
        quiet; key(62); released;

        // Sync RAM bubble exposes bogus fields; retain accepted identity.
        score_ready=0; expected_valid=0; step_index=0; expected_note=0;
        key(62); check(practice_hold,"unready practice freezes instead of leaking time");
        score_ready=1; expected_valid=1; step_index=3; expected_note=62; tick; released;
        // A new step after a bubble still requires a fresh event.
        score_ready=0; midi_note_on=1; tick;
        score_ready=1; step_index=4; tick; waiting;
        quiet; key(62); released;

        // Accepted duration survives ownership pause; waiting does not consume
        // paused events, including a pulse still high on the resume boundary.
        suspended=1; key(62); tick; released;
        suspended=0; tick; released;
        step_index=5; quiet; waiting;
        suspended=1; midi_note_on=1; tick; tick; waiting;
        suspended=0; tick; tick; waiting;
        quiet; key(62); released;

        // Same-step restart and mode changes invalidate prior acceptance.
        restart=1; midi_note_on=1; #1; waiting; tick;
        restart=0; tick; waiting; quiet; key(62); released;
        mode=0; tick; check(!practice_hold && demo_gate==0,"practice to fixed clears");
        mode=2; tick; quiet; waiting; key(62); released;
        running=0; key(62); check(!practice_hold,"stop releases external hold");
        running=1; tick; waiting; quiet; key(62); released;
        // Invalid mode is a silent fixed fallback, never a fourth audio mode.
        mode=3; tick; key(62);
        check(!practice_hold && demo_gate==0 && demo_retrigger==0,"reserved mode safe");

        mode=1; expected_note=41; step_index=0; tick; tick; demo(41,1);
        tick; demo(41,0); check(demo_velocity==192,"fixed demo velocity");
        step_index=1; tick; demo(41,1); tick; demo(41,0);
        expected_note=72; step_index=2; tick; demo(72,1); tick; demo(72,0);
        // All 32 supported pitches and representative out-of-range notes.
        for(n=41;n<=72;n=n+1) begin
            expected_note=n; step_index=step_index+1'b1; tick; demo(n,1);
            tick; demo(n,0);
        end
        expected_note=40; tick; demo(40,0);
        expected_note=73; tick; demo(73,0);
        expected_note=127; tick; demo(127,0);
        expected_note=0; tick; demo(0,0);
        expected_note=60; step_index=62; tick; demo(60,1); tick; demo(60,0);

        // No false off/retrigger when a custom long note crosses RAM quarters.
        score_ready=0; expected_valid=0; expected_note=0; step_index=0;
        tick; demo(60,0); tick; demo(60,0);
        score_ready=1; expected_valid=1; expected_note=60; step_index=62;
        tick; demo(60,0);
        // True rest immediately removes gates; next note has new identity.
        expected_valid=0; #1; check(demo_gate==0,"rest gates off without a clock");
        tick; demo(0,0); expected_valid=1; step_index=63; tick; demo(60,1);
        tick; demo(60,0); step_index=0; tick; demo(60,1); tick; demo(60,0);
        suspended=1; #1; check(demo_gate==0 && demo_retrigger==0,"pause kills demo immediately");
        tick; key(60); check(demo_gate==0,"paused MIDI cannot revive demo");
        suspended=0; tick; demo(60,1); tick; demo(60,0);
        restart=1; #1; check(demo_gate==0,"restart removes stale demo gate"); tick;
        restart=0; tick; demo(60,1); tick; demo(60,0);
        mode=2; #1; check(demo_gate==0,"mode change immediately silences demo");
        tick; quiet; waiting;
        mode=1; tick; tick; demo(60,1); tick;
        running=0; #1; check(demo_gate==0 && demo_retrigger==0,"end silences even if score stays valid");
        tick; tick; check(demo_gate==0,"end cannot retrigger");
        running=1; tick; demo(60,1);
        rst_n=0; #1; check(demo_gate==0 && demo_retrigger==0 && !practice_hold,"async reset outputs safe");
        $display("GUIDE_MODES_UNIT_PASS checks=%0d",checks); $finish;
    end
    initial begin #100000; $fatal(1,"unit watchdog"); end
endmodule
