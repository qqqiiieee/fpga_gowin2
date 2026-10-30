`timescale 1ns/1ps
// Fast, black-box V025 button regression. No DUT hierarchy or forced state.
module tb_fourphone_buttons;
    parameter integer TEST_DEBOUNCE = 4;
    localparam integer SETTLE = TEST_DEBOUNCE + 10;
    reg clk = 0, rst_n = 0;
    reg [3:0] keys_n = 4'hf;
    reg guide_done = 0, test_owned = 0;
    wire [1:0] page, song_id, cursor;
    wire song_start, song_toggle, song_restart, key_pause;
    wire [3:0] buttons_down;
    wire [2:0] pulses = {song_start, song_toggle, song_restart};
    reg [2:0] previous_pulses = 0;
    integer starts = 0, toggles = 0, restarts = 0;
    integer checks = 0, scenarios = 0, i, j;
    integer saved_starts, saved_toggles, saved_restarts;
    reg [3:0] saved_ui;

    always #5 clk = ~clk;
    four_button_display_control #(.DEBOUNCE_CYCLES(TEST_DEBOUNCE)) dut (
        .clk(clk), .rst_n(rst_n), .keys_n(keys_n),
        .guide_done(guide_done), .test_owned(test_owned),.phone_set_valid(1'b0),.phone_param(8'd0),.phone_value(8'd0),
        .page(page), .song_id(song_id), .cursor(cursor),
        .song_start(song_start), .song_toggle(song_toggle),
        .song_restart(song_restart), .key_pause(key_pause),
        .buttons_down(buttons_down)
    );

    always @(posedge clk) begin
        #1;
        if (rst_n) begin
            checks = checks + 1;
            if ((^{page, song_id, cursor, pulses, key_pause, buttons_down}) === 1'bx)
                $fatal(1, "Unknown output after reset");
            if ((pulses & previous_pulses) != 0)
                $fatal(1, "Command lasts longer than one clock");
            if (pulses != 0 && pulses != 3'b100 && pulses != 3'b010 && pulses != 3'b001)
                $fatal(1, "Overlapping song commands: %b", pulses);
            if (test_owned && pulses != 0)
                $fatal(1, "Command leaked during diagnostic ownership");
            if (buttons_down != 0 && pulses != 0)
                $fatal(1, "Command emitted before debounced release");
            if (song_id > 2 || cursor > 2)
                $fatal(1, "Song/cursor out of range");
            if (song_start) starts = starts + 1;
            if (song_toggle) toggles = toggles + 1;
            if (song_restart) restarts = restarts + 1;
            previous_pulses = pulses;
        end else begin
            starts = 0; toggles = 0; restarts = 0; previous_pulses = 0;
        end
    end

    task cycles;
        input integer n;
        begin repeat (n) begin @(posedge clk); #2; end end
    endtask
    task drive;
        input [3:0] down;
        begin @(negedge clk); keys_n = ~down; end
    endtask
    task settle;
        input [3:0] down;
        begin
            drive(down); cycles(SETTLE);
            if (buttons_down !== down)
                $fatal(1, "Debounced level got=%b expected=%b", buttons_down, down);
        end
    endtask
    task remember;
        begin
            saved_ui = {page, song_id};
            saved_starts = starts; saved_toggles = toggles; saved_restarts = restarts;
        end
    endtask
    task unchanged;
        input [511:0] label_text;
        begin
            if ({page, song_id} !== saved_ui || starts != saved_starts ||
                toggles != saved_toggles || restarts != saved_restarts)
                $fatal(1, "%0s: unexpected action page=%0d song=%0d counts=%0d/%0d/%0d",
                       label_text, page, song_id, starts, toggles, restarts);
        end
    endtask
    task state_is;
        input [1:0] p, s;
        begin
            if (page !== p || song_id !== s)
                $fatal(1, "State got page/song=%0d/%0d expected=%0d/%0d", page, song_id, p, s);
        end
    endtask
    task reset_with;
        input [3:0] down;
        begin
            @(negedge clk); rst_n = 0; keys_n = ~down; guide_done = 0; test_owned = 0;
            cycles(4);
            @(negedge clk); rst_n = 1;
            cycles(SETTLE);
            state_is(0, 0);
            if (!key_pause || pulses != 0 || starts != 0 || toggles != 0 || restarts != 0)
                $fatal(1, "Reset must be not-started, paused, and command-free");
        end
    endtask
    task click;
        input integer key;
        input [2:0] expected;
        begin
            remember;
            settle(4'b0001 << (key-1));
            unchanged("press commits before release");
            cycles(3*SETTLE);
            unchanged("held key repeats");
            settle(0);
            if (starts != saved_starts + (expected[2] ? 1 : 0) ||
                toggles != saved_toggles + (expected[1] ? 1 : 0) ||
                restarts != saved_restarts + (expected[0] ? 1 : 0))
                $fatal(1, "K%0d release command mismatch expected=%b delta=%0d/%0d/%0d",
                       key, expected, starts-saved_starts, toggles-saved_toggles, restarts-saved_restarts);
            remember; cycles(2*SETTLE); unchanged("idle repeats release");
        end
    endtask

    initial begin
        // Every physical key held through reset must be discarded, even if it
        // sees a short release glitch before the genuine stable release.
        for (i=0; i<4; i=i+1) begin
            reset_with(4'b0001 << i); remember;
            if (TEST_DEBOUNCE > 1) begin
                drive(0); cycles(1); drive(4'b0001 << i); cycles(SETTLE);
                unchanged("startup release bounce armed key");
            end
            settle(0); unchanged("startup held key fired on first release");
            cycles(SETTLE); unchanged("startup phantom event");
        end
        scenarios = scenarios + 1;

        reset_with(0);
        for (i=1; i<=4; i=i+1) begin
            click(1, 0); state_is(i % 4, 0);
        end
        scenarios = scenarios + 1;

        // First play starts; later play toggles; completion makes play start.
        click(1, 0); click(2, 3'b100); state_is(0, 0);
        if (key_pause) $fatal(1, "First start left not-started pause latched");
        click(2, 3'b010); click(2, 3'b010);
        @(negedge clk); guide_done = 1;
        click(2, 3'b100); state_is(0, 0);
        @(negedge clk); guide_done = 0;
        click(2, 3'b010);
        scenarios = scenarios + 1;

        // Restart from not-started is itself a start, with its own pulse.
        reset_with(0); click(1, 0); click(3, 3'b001); state_is(0, 0);
        if (key_pause) $fatal(1, "Restart left not-started pause latched");
        click(2, 3'b010);
        click(1, 0); click(1, 0); click(3, 3'b001); state_is(0, 0);
        scenarios = scenarios + 1;

        // Selection always goes to library and invalidates the old start.
        reset_with(0); click(2, 3'b100);
        for (i=1; i<=6; i=i+1) begin
            click(4, 0); state_is(1, i % 3);
            if (!key_pause) $fatal(1, "New song is not paused before first start");
            click(2, 3'b100); state_is(0, i % 3);
            click(2, 3'b010);
        end
        click(4, 0); click(4, 0); state_is(1, 2);
        click(3, 3'b001); state_is(0, 2); click(2, 3'b010);
        scenarios = scenarios + 1;

        if (TEST_DEBOUNCE > 1) begin
            reset_with(0); remember;
            for (i=0; i<4; i=i+1) begin
                // Each bounce pulse is separated by a fully stable idle.
                drive(4'b0001 << i); cycles(1); settle(0);
                unchanged("subthreshold press generated action");
            end
            // Bounce on both edges of K2 must yield exactly one start.
            drive(4'b0010); cycles(1); drive(0); cycles(1);
            settle(4'b0010); unchanged("press bounce generated action");
            drive(0); cycles(1); settle(4'b0010);
            unchanged("release bounce generated action");
            settle(0);
            if (starts != 1 || toggles != 0 || restarts != 0)
                $fatal(1, "Bouncy K2 was not exactly one start");
            scenarios = scenarios + 1;
        end

        // Exhaust every two-key chord, including staggered entry and partial
        // releases. A surviving single key cannot salvage a cancelled gesture.
        reset_with(0); click(2, 3'b100);
        for (i=0; i<4; i=i+1) begin
            for (j=i+1; j<4; j=j+1) begin
                remember;
                settle((4'b0001 << i) | (4'b0001 << j));
                settle(4'b0001 << j); cycles(SETTLE);
                unchanged("simultaneous chord became single action");
                settle(0); unchanged("chord release fired");
                settle(4'b0001 << i);
                settle((4'b0001 << i) | (4'b0001 << j));
                settle(4'b0001 << i); settle(0);
                unchanged("staggered chord release fired");
            end
        end
        remember; settle(4'hf); settle(4'h1); settle(0);
        unchanged("four-key chord fired");
        // Key substitution without an all-release must also cancel.
        remember; settle(4'b0010); settle(4'b0100); settle(0);
        unchanged("key substitution fired");
        click(1, 0); state_is(1, 0); click(2, 3'b010);
        scenarios = scenarios + 1;

        // Diagnostic ownership suppresses all four UI functions and discards
        // both a pre-entry candidate and a key held across ownership exit.
        for (i=0; i<4; i=i+1) begin
            reset_with(0); click(2, 3'b100); remember;
            settle(4'b0001 << i);
            @(negedge clk); test_owned = 1;
            cycles(SETTLE); settle(0); unchanged("ownership entry committed pending key");
            for (j=0; j<4; j=j+1) begin
                settle(4'b0001 << j); settle(0);
                unchanged("owned key changed UI");
            end
            settle(4'b0001 << i);
            @(negedge clk); test_owned = 0;
            cycles(2*SETTLE); unchanged("held key fired at ownership exit");
            settle(0); unchanged("stale key fired on post-ownership release");
            click(2, 3'b010); state_is(0, 0);
        end
        scenarios = scenarios + 1;

        $display("FOURPHONE_BUTTONS_PASS debounce=%0d scenarios=%0d checks=%0d",
                 TEST_DEBOUNCE, scenarios, checks);
        $finish;
    end
    initial begin #2000000; $fatal(1, "Watchdog timeout"); end
endmodule
