`timescale 1ns/1ps
// Real, unmodified guide feedback test, including its fractional BPM timing.
module tb_guide_modes_timeline;
    parameter integer RUN_MODE=2;
    parameter integer BEAT_SAMPLES=67;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, suspended=0, restart=0, midi_note_on=0;
    reg [6:0] midi_note=0;
    wire [1:0] mode=RUN_MODE;
    wire active, done, expected_valid, practice_hold;
    wire [6:0] expected_note;
    wire [5:0] step_index, total_beats;
    wire [11:0] roll_tick;
    wire [31:0] demo_gate, demo_retrigger;
    wire [7:0] demo_velocity;
    wire running=active && !done;
    wire pause=suspended || practice_hold;
    integer checks=0, used=0, want_tick, onsets=0, i, old_tick, waited;
    guide_play_modes modes(.clk(clk),.rst_n(rst_n),.mode(mode),.running(running),
        .suspended(suspended),.restart(restart),.score_ready(1'b1),
        .expected_note(expected_note),.expected_valid(expected_valid),
        .step_index(step_index),.midi_note_on(midi_note_on),.midi_note(midi_note),
        .practice_hold(practice_hold),.demo_gate(demo_gate),
        .demo_retrigger(demo_retrigger),.demo_velocity(demo_velocity));
    piano_roll_guide #(.BEAT_SAMPLES(BEAT_SAMPLES)) guide(
        .clk(clk),.rst_n(rst_n),.sample_tick(1'b1),.pause(pause),.song_id(2'd0),
        .ui_start(1'b0),.ui_toggle(1'b0),.ui_restart(restart),.roll_tick(roll_tick),
        .active(active),.done(done),.step_index(step_index),.total_beats(total_beats),
        .expected_note(expected_note),.expected_valid(expected_valid),
        .custom_write_clk(clk),.custom_write_en(1'b0),.custom_write_addr(9'd0),
        .custom_write_data(32'd0),.custom_config(32'd0));
    task check;
        input condition;
        input [8*130-1:0] message;
        begin
            checks=checks+1;
            if(condition!==1) $fatal(1,"TIMELINE_FAIL mode=%0d B=%0d step=%0d tick=%0d: %0s",
                                     RUN_MODE,BEAT_SAMPLES,step_index,roll_tick,message);
        end
    endtask
    task tick;
        begin @(posedge clk); #2; @(negedge clk); end
    endtask
    // Independent accumulator: count ONLY guide-accepted samples, then use
    // integer multiply/divide in the testbench to check exact elapsed time.
    always @(posedge clk) begin
        if(!rst_n || restart) used=0;
        else if(running && !pause) used=used+1;
        if(rst_n) begin
            if(|demo_retrigger) onsets=onsets+1;
            #1;
            want_tick=(used*64)/BEAT_SAMPLES;
            if(want_tick>total_beats*64) want_tick=total_beats*64;
            check(roll_tick==want_tick,"full fractional timeline / duration preserved");
            if(RUN_MODE!=1) check(demo_gate==0 && demo_retrigger==0,"fixed/practice cannot synthesize");
        end
    end
    initial begin
        tick; rst_n=1;
        if(RUN_MODE==2) begin
            for(i=0;i<42;i=i+1) begin
                waited=0;
                while(!(expected_valid && step_index==i)) begin tick; waited=waited+1;
                    check(waited<BEAT_SAMPLES*4,"reach next note"); end
                check(practice_hold,"first cycle at each note is frozen");
                old_tick=roll_tick;
                repeat(3) tick;
                midi_note=expected_note+1'b1; midi_note_on=1; tick; midi_note_on=0; tick;
                check(practice_hold && roll_tick==old_tick,"wrong fresh note never advances");
                if(i==1) begin
                    suspended=1; midi_note=expected_note; midi_note_on=1;
                    repeat(3) tick;
                    suspended=0; tick;
                    check(practice_hold && roll_tick==old_tick,"paused/spanning event ignored in real guide");
                    midi_note_on=0; tick;
                end
                midi_note=expected_note; midi_note_on=1; tick; midi_note_on=0;
                check(!practice_hold && roll_tick==old_tick,"fresh matching event releases without skipping time");
                if(i==6) begin
                    // First two-beat note: preserve acceptance over a pause.
                    repeat(5) tick; suspended=1; old_tick=roll_tick; repeat(4) tick;
                    check(roll_tick==old_tick,"accepted long note freezes during ownership pause");
                    suspended=0; check(!practice_hold,"accepted long note resumes without re-keying");
                end
                // Extra NoteOn is ignored during duration, not banked for the
                // following step, which may have exactly the same pitch.
                tick; midi_note_on=1; tick; midi_note_on=0;
                while(!done && step_index==i) begin tick;
                    if(!done && step_index==i) check(!practice_hold,"entire accepted note duration runs"); end
            end
        end else begin
            while(!done) begin
                tick;
                check(!practice_hold,"fixed/demo never add a pause");
            end
        end
        tick;
        check(done && !active && roll_tick==3200,"all 42 notes / 50 beats finish");
        check(demo_gate==0 && demo_retrigger==0,"natural completion releases demo");
        if(RUN_MODE==1) check(onsets==42,"exactly one retrigger per note including repetitions and long notes");
        else check(onsets==0,"no automatic note events in fixed/practice");
        repeat(5) tick;
        check(demo_gate==0 && !practice_hold,"completion remains quiescent");
        $display("GUIDE_MODES_TIMELINE_PASS mode=%0d B=%0d checks=%0d onsets=%0d samples=%0d",
                 RUN_MODE,BEAT_SAMPLES,checks,onsets,used); $finish;
    end
    initial begin #10000000; $fatal(1,"timeline watchdog"); end
endmodule
