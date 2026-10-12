`timescale 1ns/1ps
module tb_song_guide;
    parameter TEST_BEAT_SAMPLES = 16;
    reg clk = 0;
    reg rst_n = 1;
    reg sample_tick = 0;
    reg [15:0] keys = 0;
    reg ghost = 0;
    wire active, done;
    wire [11:0] cue_mask, next_mask, wrong_mask;
    wire [5:0] step_index, total_steps;
    wire [7:0] beat_progress;
    wire [1:0] target_beats;
    integer checks = 0;
    integer i, expected;
    reg [15:0] note;
    reg [2:0] song [0:41];
    always #5 clk = ~clk;

    song_guide #(.BEAT_SAMPLES(TEST_BEAT_SAMPLES)) dut (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),.pause(1'b0),
        .keys(keys), .ghost(ghost), .active(active), .done(done),
        .cue_mask(cue_mask), .next_mask(next_mask), .wrong_mask(wrong_mask),
        .step_index(step_index), .total_steps(total_steps),
        .beat_progress(beat_progress), .target_beats(target_beats)
    );

    task check;
        input condition;
        input [8*120-1:0] message;
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                $display("SONG_GUIDE_TEST_FAIL B=%0d step=%0d: %0s",
                         TEST_BEAT_SAMPLES, step_index, message);
                $fatal(1, "song_guide assertion failed");
            end
        end
    endtask

    task cycle;
        input [15:0] new_keys;
        input new_ghost;
        input tick;
        begin
            @(negedge clk);
            keys = new_keys;
            ghost = new_ghost;
            sample_tick = tick;
            @(posedge clk);
            #1;
        end
    endtask

    task held_cycles;
        input integer count;
        input tick;
        integer k;
        begin
            for (k = 0; k < count; k = k + 1)
                cycle(keys, ghost, tick);
        end
    endtask

    task reset;
        input [15:0] held_keys;
        begin
            @(negedge clk);
            keys = held_keys;
            ghost = 0;
            sample_tick = 0;
            rst_n = 0;
            #1;
            check(active === 1 && done === 0 && step_index === 0,
                  "asynchronous reset state");
            check(cue_mask === 12'h001 && next_mask === 12'h001 &&
                  total_steps === 42 && target_beats === 1 && beat_progress === 0,
                  "deterministic reset outputs");
            check(wrong_mask === (held_keys[11:0] & 12'hffe), "reset wrong mask");
            @(negedge clk);
            rst_n = 1;
            cycle(held_keys, 0, 0);
        end
    endtask

    task release_keys;
        begin
            cycle(16'h0000, 0, 0);
        end
    endtask

    task early_note;
        input integer index;
        reg [15:0] melody_key;
        begin
            melody_key = 16'h0001 << song[index];
            cycle(melody_key, 0, 0);
            check(step_index == index, "press does not advance");
            check(beat_progress == 0, "no progress without sample enable");
            release_keys;
            if (index < 41)
                check(step_index == index + 1 && active && !done,
                      "early release advances without a timing requirement");
            else
                check(step_index == 41 && !active && done, "final release completes");
        end
    endtask

    task check_timing;
        input integer beats;
        integer k, goal, last_progress;
        begin
            goal = TEST_BEAT_SAMPLES * beats;
            cycle({4'b0000, cue_mask}, 0, 0);
            held_cycles(5, 0);
            check(beat_progress == 0, "clock cycles alone do not count as samples");
            last_progress = 0;
            for (k = 1; k <= goal; k = k + 1) begin
                cycle(keys, 0, 1);
                check(beat_progress == (k * 255) / goal, "exact target fraction");
                check(beat_progress >= last_progress, "progress is monotonic");
                last_progress = beat_progress;
            end
            check(beat_progress == 255, "saturation at full duration");
            held_cycles(20, 1);
            check(beat_progress == 255, "long hold does not wrap progress");
        end
    endtask

    initial begin
        // Independent reference sequence, key indices C=0 D=1 E=2 F=3 G=4 A=5.
        song[0]=0; song[1]=0; song[2]=4; song[3]=4; song[4]=5; song[5]=5; song[6]=4;
        song[7]=3; song[8]=3; song[9]=2; song[10]=2; song[11]=1; song[12]=1; song[13]=0;
        song[14]=4; song[15]=4; song[16]=3; song[17]=3; song[18]=2; song[19]=2; song[20]=1;
        song[21]=4; song[22]=4; song[23]=3; song[24]=3; song[25]=2; song[26]=2; song[27]=1;
        song[28]=0; song[29]=0; song[30]=4; song[31]=4; song[32]=5; song[33]=5; song[34]=4;
        song[35]=3; song[36]=3; song[37]=2; song[38]=2; song[39]=1; song[40]=1; song[41]=0;

        reset(16'h0001);
        held_cycles(5, 1);
        check(beat_progress == 0 && step_index == 0, "boot-held cue is not a fresh press");
        release_keys;
        check(step_index == 0, "boot-held cue release cannot advance");

        // Wrong notes, extra melody keys (including unused upper melody keys),
        // bottom-row extras, and ghosted press/release must not progress.
        cycle(16'h0002, 0, 1);
        check(wrong_mask == 12'h002 && beat_progress == 0, "wrong single note feedback");
        release_keys;
        check(step_index == 0, "wrong note cannot advance");
        cycle(16'h0801, 0, 1);
        check(wrong_mask == 12'h800 && beat_progress == 0, "extra upper melody key rejected");
        release_keys;
        check(step_index == 0, "wrong chord cannot advance");
        cycle(16'h1001, 0, 1);
        check(wrong_mask == 0 && beat_progress == 0, "bottom-row extra rejected");
        release_keys;
        check(step_index == 0, "bottom-row extra cannot advance");
        cycle(16'h0001, 1, 1);
        held_cycles(5, 1);
        release_keys;
        check(step_index == 0, "ghosted cue cannot arm release");
        cycle(16'h0001, 0, 1);
        cycle(16'h0000, 1, 0);
        release_keys;
        check(step_index == 0 && beat_progress == 0, "ghosted release cancels a pending match");
        cycle(16'h0001, 0, 1);
        cycle(16'h0003, 0, 1);
        check(wrong_mask == 12'h002 && beat_progress == 0, "extra key cancels matching hold");
        release_keys;
        check(step_index == 0, "release after invalid hold cannot advance");

        // Direct transitions between held notes are not clean release events.
        cycle(16'h0001, 0, 0);
        cycle(16'h0002, 0, 0);
        release_keys;
        check(step_index == 0, "changing note without release cannot advance");
        cycle(16'h0001, 0, 0);
        cycle(16'h1000, 0, 0);
        release_keys;
        check(step_index == 0, "extra bottom key during release cancels match");

        check_timing(1);
        check(step_index == 0, "saturated hold cannot advance itself");
        release_keys;
        check(step_index == 1 && cue_mask == 12'h001 && beat_progress == 0,
              "first repeated C requires release and resets progress");
        held_cycles(5, 1);
        check(step_index == 1, "continued release cannot consume next repeated note");
        early_note(1);
        for (i = 2; i < 6; i = i + 1)
            early_note(i);
        check(target_beats == 2, "phrase ending has two beats");
        check_timing(2);
        check(step_index == 6, "two-beat hold still waits for release");
        release_keys;
        check(step_index == 7 && target_beats == 1, "phrase release advances");

        // Exactness and ghost rejection also apply to controls.
        cycle(16'h9001, 0, 0);
        check(active && step_index == 7, "extra melody key prevents toggle chord");
        cycle(16'h9000, 1, 0);
        check(active, "ghosted toggle chord ignored");
        release_keys;
        cycle(16'h3001, 0, 0);
        check(step_index == 7, "held melody prevents exact restart chord");
        cycle(16'h3000, 1, 0);
        check(step_index == 7, "ghosted restart ignored");
        release_keys;

        cycle(16'h0008, 0, 1);
        cycle(16'h9000, 0, 0);
        check(!active && !done && step_index == 7 && cue_mask == 0 &&
              next_mask == 0 && wrong_mask == 0 && beat_progress == 0 && target_beats == 0,
              "pause clears pending matching and hides guide");
        held_cycles(20, 1);
        check(!active, "held toggle does not autorepeat");
        cycle(16'h0000, 1, 0);
        cycle(16'h9000, 0, 0);
        check(!active, "ghosted empty scan cannot rearm toggle");
        cycle(16'h1000, 0, 0);
        cycle(16'h9000, 0, 0);
        check(!active, "toggle cannot rearm while S13 remains held");
        cycle(16'h8000, 0, 0);
        cycle(16'h9000, 0, 0);
        check(!active, "toggle cannot rearm while S16 remains held");
        cycle(16'h0008, 0, 1); // Both control members are now released.
        check(!active && step_index == 7, "free playing while paused has no effect");
        cycle(16'h9000, 0, 0);
        check(active && step_index == 7, "rearmed toggle resumes current cue");
        held_cycles(20, 0);
        check(active, "held resume chord does not toggle back");
        cycle(16'h0008, 0, 1);
        held_cycles(5, 1);
        check(beat_progress == 0 && step_index == 7, "resume requires a fresh release before press");
        release_keys;
        check(step_index == 7, "old hold cannot advance on resume release");
        early_note(7);

        // Restart requires an idle scan before accepting a held first note.
        cycle(16'h3000, 0, 0);
        check(active && !done && step_index == 0 && beat_progress == 0, "restart at first cue");
        held_cycles(20, 1);
        cycle(16'h0001, 0, 1);
        held_cycles(5, 1);
        check(step_index == 0 && beat_progress == 0, "restart-held C cannot arm release");
        release_keys;
        check(step_index == 0, "restart-held C release cannot advance");

        // Internal arming flags are checked for restart autorepeat because
        // repeated restarts at step zero have identical public outputs.
        early_note(0);
        cycle(16'h3000, 0, 0); // This one is a valid rearmed restart.
        check(step_index == 0, "restart rearmed after both constituents released");
        cycle(16'h1000, 0, 0);
        held_cycles(3, 0);
        check(dut.restart_armed == 0, "S13 held blocks restart rearm");
        cycle(16'h3000, 0, 0);
        held_cycles(20, 0);
        check(dut.restart_armed == 0, "held restart has no autorepeat");
        cycle(16'h0000, 1, 0);
        cycle(16'h3000, 0, 0);
        check(dut.restart_armed == 0, "ghosted empty scan cannot rearm restart");
        cycle(16'h2000, 0, 0);
        check(dut.restart_armed == 0, "S14 held blocks restart rearm");
        cycle(16'h3000, 0, 0);
        release_keys;
        check(dut.restart_armed == 1, "both restart constituents released rearm it");

        // A full uninterrupted rendition verifies every cue, preview, duration,
        // repeated note, and completion boundary against the reference score.
        for (i = 0; i < 42; i = i + 1) begin
            note = 16'h0001 << song[i];
            check(active && !done && step_index == i && total_steps == 42,
                  "full-song active step count");
            check(cue_mask == note[11:0], "full-song melody cue");
            if (i == 41)
                check(next_mask == 0, "final cue has no preview");
            else
                check(next_mask == (12'h001 << song[i+1]), "following melody preview");
            expected = ((i % 7) == 6) ? 2 : 1;
            check(target_beats == expected, "all six phrase-ending durations");
            early_note(i);
        end
        check(done && !active && cue_mask == 0 && next_mask == 0 &&
              wrong_mask == 0 && beat_progress == 0 && target_beats == 0,
              "all completion outputs deterministic");
        cycle(16'h0001, 0, 1);
        release_keys;
        cycle(16'h9000, 0, 0);
        held_cycles(20, 1);
        release_keys;
        check(done && !active && step_index == 41 && cue_mask == 0,
              "completion remains latched through playing and toggle");
        cycle(16'h3000, 0, 0);
        check(active && !done && step_index == 0 && cue_mask == 12'h001,
              "restart clears completion");
        release_keys;
        early_note(0);

        // Restart also enters active guide mode directly from free mode.
        cycle(16'h9000, 0, 0);
        check(!active && step_index == 1, "pause before restart");
        release_keys;
        cycle(16'h3000, 0, 0);
        check(active && !done && step_index == 0, "restart from pause activates guide");
        reset(16'h0802);
        check(wrong_mask == 12'h802, "reset drives wrong feedback for current keys");
        release_keys;
        $display("SONG_GUIDE_TEST_PASS BEAT_SAMPLES=%0d checks=%0d full42steps one/two-beat timing controls release/ghost",
                 TEST_BEAT_SAMPLES, checks);
        $finish;
    end
    initial begin
        #100000000;
        $fatal(1, "song_guide simulation timeout");
    end
endmodule
