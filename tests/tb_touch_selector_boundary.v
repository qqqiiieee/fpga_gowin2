`timescale 1ns/1ps
// Standalone boundary regression using only public input stimulus. No forced DUT state.
// Example: iverilog -g2012 -s tb_touch_selector_boundary -o boundary.vvp
//          src/matrix_keypad.v tests/tb_touch_selector_boundary.v
// ROW_CYCLES=12 sweeps every clock position in a complete scan. For a bounded
// production-period check use ROW_CYCLES=6750, PHASE_COUNT=1.
module tb_touch_selector_boundary #(
    parameter ROW_CYCLES = 12,
    parameter DEBOUNCE_FRAMES = 3,
    parameter PHASE_COUNT = 0
);
    localparam FRAME_CYCLES = 4 * ROW_CYCLES;
    localparam SETTLE = FRAME_CYCLES * (DEBOUNCE_FRAMES + 3) + 8;
    localparam PHASES = (PHASE_COUNT > 0) ? PHASE_COUNT : FRAME_CYCLES;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0, remote = 0;
    reg [15:0] physical = 0, touch = 0, virtual_keys = 0;
    wire [3:0] rows;
    reg [3:0] cols;
    wire [15:0] keys;
    wire [3:0] selected;
    wire note_on, note_off, ghost;
    wire [6:0] note;
    integer ons = 0, offs = 0, selection_changes = 0;
    reg [3:0] previous_selected = 0;
    integer source_cases = 0, outgoing_cases = 0, ghost_cases = 0;

    matrix_keypad #(
        .ROW_CYCLES(ROW_CYCLES), .DEBOUNCE_FRAMES(DEBOUNCE_FRAMES),
        .PERFORMANCE_MODE(1), .SELECT_ON_RELEASE(1), .TWO_BUTTON_SELECT(1),
        .TIMBRE_COUNT(2), .EXTERNAL_KEYS_ENABLE(1)
    ) dut (
        .clk(clk), .rst_n(rst_n), .suppress_select(1'b0), .rows(rows), .cols(cols),
        .virtual_enable(remote), .virtual_keys(virtual_keys), .velocity(8'd160),
        .note_on(note_on), .note_off(note_off), .note(note), .vel_out(),
        .timbre_out(), .key_state(keys), .ghost_active(ghost),
        .selected_timbre(selected), .external_keys(touch)
    );

    // Passive matrix network, including genuine three-corner ghost propagation.
    reg [3:0] reached_rows, reached_cols;
    integer pass, r, c;
    always @(*) begin
        reached_rows = 0;
        reached_cols = 0;
        for (r = 0; r < 4; r = r + 1)
            if (rows[r] === 1'b0) reached_rows[r] = 1;
        for (pass = 0; pass < 8; pass = pass + 1)
            for (r = 0; r < 4; r = r + 1)
                for (c = 0; c < 4; c = c + 1)
                    if (physical[r*4+c]) begin
                        if (reached_rows[r]) reached_cols[c] = 1;
                        if (reached_cols[c]) reached_rows[r] = 1;
                    end
        cols = ~reached_cols;
    end

    always @(posedge clk) begin
        #1;
        if (!rst_n) begin
            ons = 0; offs = 0; selection_changes = 0; previous_selected = 0;
        end else begin
            if (selected !== previous_selected) selection_changes = selection_changes + 1;
            previous_selected = selected;
            if (note_on && note_off) $fatal(1, "TOUCH_SELECTOR_BOUNDARY simultaneous events");
            if (note_on) begin
                ons = ons + 1;
                if (note !== 60) $fatal(1, "TOUCH_SELECTOR_BOUNDARY unexpected note-on %0d", note);
            end
            if (note_off) begin
                offs = offs + 1;
                if (note !== 60) $fatal(1, "TOUCH_SELECTOR_BOUNDARY unexpected note-off %0d", note);
            end
        end
    end

    task cycles;
        input integer count;
        begin repeat (count) @(negedge clk); end
    endtask

    task need;
        input condition;
        input [1023:0] message;
        begin
            if (condition !== 1'b1) begin
                $display("TOUCH_SELECTOR_BOUNDARY_COUNTEREXAMPLE time=%0t remote=%b physical=%h touch=%h virtual=%h keys=%h chosen=%0d changes=%0d on=%0d off=%0d: %0s",
                    $time, remote, physical, touch, virtual_keys, keys,
                    selected, selection_changes, ons, offs, message);
                $fatal(1, "TOUCH_SELECTOR_BOUNDARY failed");
            end
        end
    endtask

    task reset_case;
        input initial_remote;
        begin
            @(negedge clk); rst_n = 0;
            remote = initial_remote; physical = 0; touch = 0; virtual_keys = 0;
            cycles(5); rst_n = 1; cycles(SETTLE);
            need(keys === 0 && selected === 0 && !ghost, "clean reset and source settling");
        end
    endtask

    // In local mode the touch input remains one-hot; the optional matrix holds S1.
    task drive_source;
        input [15:0] mask;
        begin
            @(negedge clk);
            if (remote) virtual_keys = mask;
            else begin touch = mask & 16'hf000; physical = mask & 16'h0fff; end
            cycles(SETTLE);
        end
    endtask

    task clear_all;
        begin
            @(negedge clk); physical = 0; touch = 0; virtual_keys = 0;
            cycles(SETTLE);
        end
    endtask

    task fresh_gesture;
        input [15:0] selector;
        begin
            need(selection_changes == 0 && selected == 0, "cancelled gesture never changed timbre");
            drive_source(selector);
            need(keys === selector && selected == 0, "fresh selector held without auto-repeat");
            drive_source(0);
            need(keys == 0 && selected == 1 && selection_changes == 1,
                "fresh clean release must select exactly once after rearming");
            cycles(SETTLE);
            need(selection_changes == 1 && ons == 1 && offs == 1,
                "no delayed selection or missing/duplicated ordinary-note release");
        end
    endtask

    integer direction, selector_index, phase, offset;
    reg [15:0] selector;
    initial begin
        // Original bug: an incoming selector was already held while the selected
        // source was idle. Switching source must not arm that existing gesture.
        for (direction = 0; direction < 2; direction = direction + 1)
            for (selector_index = 0; selector_index < 2; selector_index = selector_index + 1) begin
                selector = 16'h1000 << selector_index;
                for (phase = 0; phase < PHASES; phase = phase + 1) begin
                    reset_case(direction == 1);
                    @(negedge clk);
                    if (direction == 0) virtual_keys = selector | 16'h0001;
                    else begin touch = selector; physical = 16'h0001; end
                    offset = phase * FRAME_CYCLES / PHASES;
                    cycles(FRAME_CYCLES + offset);
                    need(keys == 0 && ons == 0, "incoming source must remain invisible before handoff");
                    @(negedge clk); remote = !remote; cycles(SETTLE);
                    need(keys === (selector | 16'h0001) && selected == 0 && ons == 1 && offs == 0,
                        "handoff must expose ordinary note and held selector without selecting");
                    drive_source(16'h0001);
                    need(keys === 16'h0001 && selected == 0 && selection_changes == 0,
                        "release of selector held before source handoff must be cancelled");
                    clear_all();
                    need(keys == 0 && ons == 1 && offs == 1, "ordinary note must release during lockout");
                    fresh_gesture(selector);
                    source_cases = source_cases + 1;
                end
            end

        // The outgoing source's pending selector release is also cancelled.
        for (direction = 0; direction < 2; direction = direction + 1)
            for (selector_index = 0; selector_index < 2; selector_index = selector_index + 1) begin
                selector = 16'h1000 << selector_index;
                reset_case(direction == 1);
                drive_source(selector | 16'h0001);
                need(keys === (selector | 16'h0001) && ons == 1, "outgoing pending gesture precondition");
                @(negedge clk); remote = !remote; cycles(SETTLE);
                need(keys == 0 && selected == 0 && selection_changes == 0 && offs == 1,
                    "source-generated release must cancel old candidate and release ordinary note");
                clear_all(); fresh_gesture(selector);
                outgoing_cases = outgoing_cases + 1;
            end

        // A ghost rectangle in the optional matrix cancels a touch selector,
        // preserves an already-held ordinary note, and permits a fresh gesture.
        for (selector_index = 0; selector_index < 2; selector_index = selector_index + 1) begin
            selector = 16'h1000 << selector_index;
            reset_case(0); drive_source(selector | 16'h0001);
            @(negedge clk); physical = 16'h0013; cycles(SETTLE);
            need(ghost && keys === (selector | 16'h0001) && ons == 1 && offs == 0,
                "matrix ghost must preserve held note and suppress new phantom notes");
            @(negedge clk); physical = 16'h0001; cycles(SETTLE);
            need(!ghost && selected == 0, "ghost removal must not restore cancelled candidate");
            drive_source(16'h0001);
            need(selected == 0 && selection_changes == 0, "ghost-cancelled touch release must not select");
            clear_all(); fresh_gesture(selector);
            ghost_cases = ghost_cases + 1;
        end
        $display("TOUCH_SELECTOR_BOUNDARY_TEST_PASS row_cycles=%0d phases=%0d incoming_cases=%0d outgoing_cases=%0d ghost_cases=%0d both_selectors=1 note_events_preserved=1 fresh_gestures=1",
            ROW_CYCLES, PHASES, source_cases, outgoing_cases, ghost_cases);
        $finish;
    end
    initial begin
        #2000000000;
        $fatal(1, "TOUCH_SELECTOR_BOUNDARY timeout");
    end
endmodule
