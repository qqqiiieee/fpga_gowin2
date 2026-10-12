`timescale 1ns/1ps
module tb_song_library;
    parameter TEST_BEAT_SAMPLES = 16;
    // Small beats check every sample of every note. Production beats can check
    // the first short/long notes plus every cue/duration/completion boundary.
    parameter FULL_TIMING = 1;
    localparam BEAT_LENGTH = (TEST_BEAT_SAMPLES < 1) ? 1 : TEST_BEAT_SAMPLES;
    reg clk = 0;
    reg rst_n = 1;
    reg sample_tick = 0;
    reg pause = 0;
    reg [15:0] keys = 0;
    reg ghost = 0;
    reg [1:0] song_id = 0;
    reg ui_start = 0, ui_toggle = 0, ui_restart = 0;
    wire active, done;
    wire [11:0] cue_mask, next_mask, wrong_mask;
    wire [5:0] step_index, total_steps;
    wire [7:0] beat_progress;
    wire [1:0] target_beats;
    // Explicitly drive the added inputs into a default-parameter instance too:
    // it must ignore pulses, IDs, X and Z as well as omitted legacy ports.
    wire legacy_active, legacy_done;
    wire [11:0] legacy_cue, legacy_next, legacy_wrong;
    wire [5:0] legacy_step, legacy_total;
    wire [7:0] legacy_progress;
    wire [1:0] legacy_beats;
    integer checks = 0;
    integer s, i, k, n, goal, expected, first_long;
    reg [15:0] note;
    reg [2:0] score [0:105];
    reg [1:0] rhythm [0:105];
    reg [127:0] frozen_state;
    always #5 clk = ~clk;

    song_guide #(.BEAT_SAMPLES(TEST_BEAT_SAMPLES), .EXTERNAL_UI(1)) dut (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick), .pause(pause),
        .keys(keys), .ghost(ghost), .active(active), .done(done),
        .cue_mask(cue_mask), .next_mask(next_mask), .wrong_mask(wrong_mask),
        .step_index(step_index), .total_steps(total_steps),
        .beat_progress(beat_progress), .target_beats(target_beats),
        .song_id(song_id), .ui_start(ui_start), .ui_toggle(ui_toggle),
        .ui_restart(ui_restart)
    );
    song_guide #(.BEAT_SAMPLES(TEST_BEAT_SAMPLES)) legacy (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick), .pause(pause),
        .keys(keys), .ghost(ghost), .active(legacy_active), .done(legacy_done),
        .cue_mask(legacy_cue), .next_mask(legacy_next), .wrong_mask(legacy_wrong),
        .step_index(legacy_step), .total_steps(legacy_total),
        .beat_progress(legacy_progress), .target_beats(legacy_beats),
        .song_id(song_id), .ui_start(ui_start), .ui_toggle(ui_toggle),
        .ui_restart(ui_restart)
    );

    function integer length;
        input integer sid;
        begin length = (sid == 0) ? 42 : 32; end
    endfunction
    function integer offset;
        input integer sid;
        begin
            case (sid)
                0: offset = 0;
                1: offset = 42;
                default: offset = 74;
            endcase
        end
    endfunction
    function [11:0] ref_mask;
        input integer sid;
        input integer index;
        begin ref_mask = 12'h001 << score[offset(sid)+index]; end
    endfunction
    function [127:0] state;
        input unused;
        begin
            state = {active, done, step_index, total_steps, cue_mask, next_mask,
                     target_beats, beat_progress, dut.phase, dut.selected_song,
                     dut.matched, dut.release_required, dut.toggle_armed,
                     dut.restart_armed};
        end
    endfunction
    task check;
        input condition;
        input [8*140-1:0] message;
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                $display("SONG_LIBRARY_TEST_FAIL B=%0d song=%0d step=%0d: %0s",
                         TEST_BEAT_SAMPLES, dut.selected_song, step_index, message);
                $fatal(1, "song library assertion failed");
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
    task command;
        input [1:0] sid;
        input start_request, toggle_request, restart_request;
        begin
            // Match the top contract: selection is stable a full clock before
            // the command, and each command is exactly one rising clock long.
            @(negedge clk);
            song_id = sid;
            @(posedge clk); #1;
            @(negedge clk);
            ui_start = start_request;
            ui_toggle = toggle_request;
            ui_restart = restart_request;
            @(posedge clk); #1;
            @(negedge clk);
            ui_start = 0;
            ui_toggle = 0;
            ui_restart = 0;
            #1;
        end
    endtask
    task load_score;
        input integer sid;
        input [8*42-1:0] letters;
        integer j;
        reg [7:0] letter;
        begin
            for (j = 0; j < length(sid); j = j + 1) begin
                letter = letters >> (8*(length(sid)-1-j));
                case (letter)
                    "C": score[offset(sid)+j] = 0;
                    "D": score[offset(sid)+j] = 1;
                    "E": score[offset(sid)+j] = 2;
                    "F": score[offset(sid)+j] = 3;
                    "G": score[offset(sid)+j] = 4;
                    "A": score[offset(sid)+j] = 5;
                    default: $fatal(1, "invalid independent reference score");
                endcase
                rhythm[offset(sid)+j] = 1;
            end
        end
    endtask
    task release_keys;
        begin cycle(16'h0000, 0, 0); end
    endtask
    task start_song;
        input [1:0] sid;
        begin
            pause = 1;
            cycle({4'b0, ref_mask(sid, 0)}, 0, 0);
            command(sid, 1, 0, 0);
            check(active && !done && step_index == 0 && beat_progress == 0,
                  "start works while menu pause is asserted");
            check(total_steps == length(sid) && cue_mask == ref_mask(sid, 0) &&
                  next_mask == ref_mask(sid, 1), "start latches selected score");
            check(dut.release_required && !dut.matched && dut.phase == 0,
                  "start resets all pending hold state");
            // A selected note already held at start is not a new press.
            pause = 0;
            cycle({4'b0, cue_mask}, 0, 1);
            cycle(keys, 0, 1);
            check(step_index == 0 && beat_progress == 0, "start-held note ignored");
            release_keys;
            check(step_index == 0, "start-held release does not advance");
        end
    endtask
    task invalid_keys;
        input integer sid;
        reg [15:0] correct, wrong;
        begin
            correct = {4'b0, ref_mask(sid, 0)};
            wrong = (correct == 16'h0001) ? 16'h0002 : 16'h0001;
            cycle(wrong, 0, 1);
            check(wrong_mask == wrong[11:0] && beat_progress == 0, "wrong key feedback");
            release_keys;
            check(step_index == 0, "wrong note release rejected");
            cycle(correct | 16'h0800, 0, 1);
            check(wrong_mask == 12'h800 && beat_progress == 0, "S12 extra rejected");
            release_keys;
            cycle(correct | 16'h1000, 0, 1);
            check(wrong_mask == 0 && beat_progress == 0, "control-key extra rejected");
            release_keys;
            check(step_index == 0, "extra-key releases rejected");
            cycle(correct, 1, 1);
            release_keys;
            check(step_index == 0, "ghosted press rejected");
            cycle(correct, 0, 1);
            cycle(16'h0000, 1, 1);
            release_keys;
            check(step_index == 0 && beat_progress == 0, "ghosted release cancels match");
            cycle(correct, 0, 1);
            cycle(correct | wrong, 0, 1);
            release_keys;
            check(step_index == 0, "invalid hold cancels pending release");
            cycle(correct, 0, 0);
            cycle(wrong, 0, 0);
            release_keys;
            check(step_index == 0, "direct key transition cannot advance");
        end
    endtask
    task check_pause;
        input integer sid;
        reg [15:0] correct;
        integer j;
        begin
            correct = {4'b0, ref_mask(sid, 0)};
            cycle(correct, 0, 1);
            check(dut.matched, "correct press sets pending match");
            pause = 1;
            frozen_state = state(1'b0);
            for (j = 0; j < 24; j = j + 1) begin
                // Selection, scan/ghost, sample tick and both old chords can
                // change on the menu page without changing the saved song state.
                song_id = (sid + 1) % 3;
                case (j % 4)
                    0: cycle(16'h3000, 0, 1);
                    1: cycle(16'h9000, 0, 1);
                    2: cycle(16'h0000, 1, 1);
                    3: cycle(16'h0000, 0, 1);
                endcase
                check(state(1'b0) === frozen_state, "pause freezes score/timer/pending/arming");
            end
            // The old pending note can continue at the exact saved fraction.
            pause = 0;
            cycle(correct, 0, 0);
            check(state(1'b0) === frozen_state, "resume without tick preserves fraction");
            cycle(correct, 0, 1);
            check(dut.selected_song == sid && step_index == 0 && dut.matched,
                  "resume continues the latched song");
            release_keys;
            check(step_index == 1 && beat_progress == 0, "saved match advances on clean release");
        end
    endtask
    task timing;
        input integer sid;
        input integer index;
        integer j, duration, previous;
        begin
            duration = BEAT_LENGTH * rhythm[offset(sid)+index];
            cycle({4'b0, ref_mask(sid, index)}, 0, 0);
            cycle(keys, 0, 0);
            check(beat_progress == 0, "no progress without sample tick");
            previous = 0;
            for (j = 1; j <= duration; j = j + 1) begin
                cycle(keys, 0, 1);
                check(beat_progress == (j*255)/duration && beat_progress >= previous,
                      "every sample matches independent beat fraction");
                check(step_index == index && active && !done,
                      "held note never advances, even at full beat");
                previous = beat_progress;
            end
            cycle(keys, 0, 1);
            cycle(keys, 0, 1);
            check(beat_progress == 255, "progress saturates without wrapping");
        end
    endtask

    initial begin
        load_score(0, "CCGGAAGFFEEDDCGGFFEEDGGFFEEDCCGGAAGFFEEDDC");
        load_score(1, "EEFGGFEDCCDEEDDDEEFGGFEDCCDEDCCC");
        load_score(2, "CDECCDECEFGEFGGAGFECGAGFECCGCCGC");
        for (i = 6; i < 42; i = i + 7) rhythm[i] = 2;
        rhythm[42+7]=2; rhythm[42+15]=2; rhythm[42+23]=2; rhythm[42+31]=2;
        rhythm[74+10]=2; rhythm[74+13]=2; rhythm[74+28]=2; rhythm[74+31]=2;

        @(negedge clk); rst_n = 0; #1;
        check(active && !done && step_index == 0 && total_steps == 42 &&
              cue_mask == 12'h001 && next_mask == 12'h001, "legacy-compatible reset");
        @(negedge clk); rst_n = 1;
        pause = 1;
        frozen_state = {legacy_active, legacy_done, legacy_step, legacy_total,
                        legacy_cue, legacy_next, legacy_wrong, legacy_progress, legacy_beats};
        command(2, 1, 1, 1);
        check({legacy_active, legacy_done, legacy_step, legacy_total, legacy_cue,
               legacy_next, legacy_wrong, legacy_progress, legacy_beats} === frozen_state,
              "default parameter ignores asserted appended commands");
        song_id = 2'bzz; ui_start = 1'bz; ui_toggle = 1'bz; ui_restart = 1'bz;
        cycle(0, 0, 1);
        check(legacy_total === 42 && legacy_cue === 12'h001 && legacy_progress === 0,
              "default parameter ignores Z on added ports");
        song_id = 2'bxx; ui_start = 1'bx; ui_toggle = 1'bx; ui_restart = 1'bx;
        cycle(0, 0, 1);
        check(legacy_total === 42 && legacy_cue === 12'h001 && legacy_active === 1,
              "default parameter ignores X on added ports");
        song_id = 0; ui_start = 0; ui_toggle = 0; ui_restart = 0;

        for (s = 0; s < 3; s = s + 1) begin
            start_song(s);
            invalid_keys(s);
            check_pause(s);
            // A paused restart must clear the saved state and capture a new ID.
            pause = 1;
            command(s, 0, 0, 1);
            check(step_index == 0 && active && !done && total_steps == length(s) &&
                  beat_progress == 0 && !dut.matched && dut.release_required &&
                  dut.phase == 0, "UI restart takes priority over pause");
            pause = 0;
            release_keys;
            first_long = 0;
            for (i = 0; i < length(s); i = i + 1) begin
                check(active && !done && step_index == i && total_steps == length(s),
                      "every active step uses selected song length");
                check(cue_mask == ref_mask(s, i), "every cue matches independent score");
                if (i+1 < length(s))
                    check(next_mask == ref_mask(s, i+1), "every next note matches score");
                else
                    check(next_mask == 0, "last step has no preview");
                expected = rhythm[offset(s)+i];
                check(target_beats == expected, "every note has reference rhythm");
                if (FULL_TIMING || i == 0 || (expected == 2 && !first_long)) begin
                    timing(s, i);
                    if (expected == 2) first_long = 1;
                end else begin
                    cycle({4'b0, ref_mask(s, i)}, 0, 0);
                    check(step_index == i && beat_progress == 0, "early press waits for release");
                end
                release_keys;
                check(beat_progress == 0, "release resets beat fraction");
                if (i+1 < length(s)) begin
                    check(step_index == i+1 && active && !done, "release advances one step");
                    release_keys;
                    check(step_index == i+1, "idle release cannot consume repeated note");
                end else begin
                    check(step_index == length(s)-1 && done && !active && cue_mask == 0 &&
                          next_mask == 0 && wrong_mask == 0 && target_beats == 0,
                          "last release completes with deterministic outputs");
                end
            end
            pause = 1;
            command(s, 0, 1, 0);
            check(done && !active && step_index == length(s)-1, "UI toggle preserves completion");
            pause = 0;
            release_keys;
            cycle(16'h9000, 0, 0);
            check(done && !active, "old toggle also preserves completion");
            release_keys;
            cycle(16'h3000, 0, 0);
            check(active && !done && step_index == 0 && total_steps == length(s) &&
                  cue_mask == ref_mask(s, 0), "old restart retains selected song after completion");
            cycle(16'h3000, 0, 1);
            check(!dut.restart_armed, "old restart held chord cannot autorepeat");
            cycle(16'h1000, 0, 0);
            check(!dut.restart_armed, "S13 alone prevents old restart rearm");
            release_keys;
            check(dut.restart_armed, "both old restart keys released rearm chord");
            cycle({4'b0, cue_mask}, 0, 1);
            pause = 1;
            command(s, 0, 1, 0);
            check(!active && !done && step_index == 0 && !dut.matched &&
                  dut.release_required && beat_progress == 0 && dut.phase == 0,
                  "UI toggle while paused resets pending match and timer");
            command(s, 0, 1, 0);
            check(active && !done && step_index == 0 && dut.release_required,
                  "second one-cycle UI toggle resumes while paused");
            pause = 0;
            cycle({4'b0, cue_mask}, 0, 1);
            check(beat_progress == 0 && !dut.matched, "UI resume rejects still-held note");
            release_keys;
            check(step_index == 0, "UI toggle canceled the old pending release");
            cycle(16'h9001, 0, 0);
            cycle(16'h9000, 1, 0);
            check(active, "old toggle rejects extras and ghost in external mode");
            release_keys;
            cycle(16'h9000, 0, 0);
            check(!active && step_index == 0, "old toggle still works on playing page");
            cycle(16'h9000, 0, 1);
            check(!active && !dut.toggle_armed, "held old toggle cannot autorepeat");
            cycle(16'h8000, 0, 0);
            check(!dut.toggle_armed, "S16 alone blocks old toggle rearm");
            release_keys;
            cycle(16'h9000, 0, 0);
            check(active && dut.release_required, "old toggle resumes with fresh-release requirement");
            release_keys;
            $display("SONG_LIBRARY_SCORE_PASS id=%0d steps=%0d every_note/every_beat/release/pause/controls", s, length(s));
        end

        // Switch away from a matched note while paused; old release must not
        // leak into the new song, even when start and toggle share a clock.
        cycle({4'b0, cue_mask}, 0, 1);
        pause = 1;
        command(1, 1, 1, 0);
        check(active && !done && step_index == 0 && total_steps == 32 &&
              cue_mask == 12'h004 && beat_progress == 0 && dut.release_required &&
              !dut.matched, "start changes song and wins over simultaneous toggle");
        pause = 0;
        release_keys;
        check(step_index == 0, "old matched-note release does not enter new song");
        cycle(16'h0004, 0, 0);
        release_keys;
        check(step_index == 1, "new song requires its own press/release");
        pause = 1;
        command(2, 0, 1, 1);
        check(active && !done && step_index == 0 && cue_mask == 12'h001 &&
              next_mask == 12'h002 && total_steps == 32, "restart changes song and wins over toggle");
        frozen_state = state(1'b0);
        cycle(0, 0, 1);
        check(state(1'b0) === frozen_state, "one-clock UI restart does not repeat after pulse");
        command(3, 1, 0, 0);
        check(active && !done && total_steps == 42 && cue_mask == 12'h001 &&
              next_mask == 12'h001, "invalid song ID deterministically selects song zero");

        // UI start and UI restart must also clear a latched completion while
        // the library/menu page keeps pause asserted.
        pause = 0;
        release_keys;
        for (i = 0; i < 42; i = i + 1) begin
            cycle({4'b0, ref_mask(0, i)}, 0, 0);
            release_keys;
        end
        check(done && !active && step_index == 41, "complete before menu start");
        pause = 1;
        command(1, 1, 0, 0);
        check(active && !done && step_index == 0 && total_steps == 32 &&
              cue_mask == ref_mask(1, 0) && dut.release_required && !dut.matched,
              "paused menu start clears completion and selects a different song");
        pause = 0;
        release_keys;
        for (i = 0; i < 32; i = i + 1) begin
            cycle({4'b0, ref_mask(1, i)}, 0, 0);
            release_keys;
        end
        check(done && !active && step_index == 31, "complete before menu restart");
        pause = 1;
        command(2, 0, 0, 1);
        check(active && !done && step_index == 0 && total_steps == 32 &&
              cue_mask == ref_mask(2, 0) && next_mask == ref_mask(2, 1) &&
              beat_progress == 0 && dut.phase == 0 && dut.release_required && !dut.matched,
              "paused menu restart clears completion and selects a different song");

        // A default instance with connected controls still performs the original
        // 42 notes; continuously varying the extra UI ports must have no effect.
        @(negedge clk); rst_n = 0; keys = 0; pause = 0; #1;
        @(negedge clk); rst_n = 1;
        release_keys;
        for (i = 0; i < 42; i = i + 1) begin
            @(negedge clk);
            song_id = i % 4; ui_start = 1; ui_toggle = 1; ui_restart = 1;
            check(legacy_step == i && legacy_total == 42 && legacy_cue == ref_mask(0, i) &&
                  legacy_beats == rhythm[i], "default instance retains every original cue/beat");
            cycle({4'b0, ref_mask(0, i)}, 0, 0);
            release_keys;
        end
        check(legacy_done && !legacy_active && legacy_step == 41 && legacy_cue == 0 &&
              legacy_next == 0 && legacy_beats == 0, "default connected-UI instance completes old 42 steps");
        $display("SONG_LIBRARY_TEST_PASS BEAT_SAMPLES=%0d FULL_TIMING=%0d checks=%0d scores=42/32/32 legacy42",
                 TEST_BEAT_SAMPLES, FULL_TIMING, checks);
        $finish;
    end
    initial begin
        #200000000;
        $fatal(1, "song library simulation timeout");
    end
endmodule
