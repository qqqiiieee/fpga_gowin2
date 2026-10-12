`timescale 1ns/1ps

// Verilog-2001, black-box protocol test. All commands enter through uart_rx;
// all ACKs are decoded from uart_tx. No hierarchical pokes or serial hardware.
module tb_remote_link;
    localparam integer CLK_HZ         = 100000;
    localparam integer BAUD           = 10000;
    localparam integer TIMEOUT_CYCLES = 10000;
    localparam integer BIT_CLKS       = CLK_HZ / BAUD;
    localparam integer FRAGMENT_CLKS  = CLK_HZ / 50; // 20 ms
    localparam integer ACK_WAIT_CLKS  = (16 * 12 + 8) * BIT_CLKS;
    localparam integer COMMAND_CLKS   = 16 * (10 * BIT_CLKS + 1) + 8;
    localparam real CLOCK_NS          = 1000000000.0 / CLK_HZ;
    localparam real BIT_NS            = 1000000000.0 / BAUD;

    reg clk;
    reg rst_n;
    reg uart_rx;
    wire uart_tx;
    reg [15:0] physical_keys;
    reg [63:0] physical_adc;
    reg [7:0] status_flags;
    wire remote_active;
    wire zero_mode;
    wire park_i2c;
    wire [15:0] virtual_keys;
    wire [7:0] velocity;
    wire [63:0] virtual_adc;
    wire accepted;
    wire [7:0] last_seq;

    remote_debug_link #(
        .CLK_HZ(CLK_HZ),
        .BAUD(BAUD),
        .TIMEOUT_CYCLES(TIMEOUT_CYCLES)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .uart_rx(uart_rx), .uart_tx(uart_tx),
        .physical_keys(physical_keys), .physical_adc(physical_adc),
        .status_flags(status_flags),
        .remote_active(remote_active), .zero_mode(zero_mode),
        .park_i2c(park_i2c), .virtual_keys(virtual_keys),
        .velocity(velocity), .virtual_adc(virtual_adc),
        .accepted(accepted), .last_seq(last_seq)
    );

    reg [7:0] command_bytes [0:15];
    reg [7:0] expected_ack [0:15];
    reg ack_pending;
    integer ack_packets;
    integer ack_byte_index;
    integer ack_target;
    reg [7:0] ack_running_xor;
    reg [7:0] decoded_byte;
    integer decode_bit;

    integer clock_count;
    integer accepted_count;
    integer last_accept_cycle;
    reg accepted_previous;
    reg commit_pending;
    reg [7:0] commit_flags, commit_seq, commit_velocity;
    reg [15:0] commit_keys;
    reg [63:0] commit_adc;
    reg guard_outputs;
    reg held_active, held_zero, held_park;
    reg [15:0] held_keys;
    reg [7:0] held_velocity, held_seq;
    reg [63:0] held_adc;
    integer held_accepts;
    integer final_accepts, final_acks;
    integer reset_ack_count;
    integer reserved_flag_bit;

    always #(CLOCK_NS / 2.0) clk = ~clk;

    task fail;
        input [8*192-1:0] reason;
        begin
            $display("REMOTE_LINK_TEST_FAIL at %0t: %0s", $time, reason);
            $finish;
        end
    endtask

    // Freeze every externally visible command output, not just remote_active.
    task freeze_outputs;
        begin
            held_active   = remote_active;
            held_zero     = zero_mode;
            held_park     = park_i2c;
            held_keys     = virtual_keys;
            held_velocity = velocity;
            held_adc      = virtual_adc;
            held_seq      = last_seq;
            held_accepts  = accepted_count;
            guard_outputs = 1'b1;
        end
    endtask

    task check_frozen;
        begin
            if ((remote_active !== held_active) ||
                (zero_mode !== held_zero) || (park_i2c !== held_park) ||
                (virtual_keys !== held_keys) || (velocity !== held_velocity) ||
                (virtual_adc !== held_adc) || (last_seq !== held_seq) ||
                (accepted_count != held_accepts))
                fail("Incomplete/rejected packet or idle input changed command outputs");
        end
    endtask

    // Delay past DUT nonblocking assignments before observing its outputs.
    always @(posedge clk) begin
        #1;
        clock_count = clock_count + 1;
        if (!rst_n) begin
            accepted_count = 0;
            accepted_previous = 1'b0;
            last_accept_cycle = -1;
        end else begin
            if ((accepted !== 1'b0) && (accepted !== 1'b1))
                fail("accepted contains X/Z");
            if (accepted) begin
                if (accepted_previous)
                    fail("accepted is longer than one clock");
                if (!commit_pending)
                    fail("Rejected command generated an accepted pulse");
                if ((remote_active !== commit_flags[0]) ||
                    (zero_mode !== commit_flags[1]) ||
                    (park_i2c !== commit_flags[2]) || (last_seq !== commit_seq))
                    fail("Flags/sequence were not atomically committed on accepted");
                if (commit_flags[0]) begin
                    if ((virtual_keys !== commit_keys) ||
                        (velocity !== commit_velocity) || (virtual_adc !== commit_adc))
                        fail("Keys/velocity/ADC were not atomically committed on accepted");
                end else if (virtual_keys !== 16'h0000) begin
                    fail("Disabled command did not clear keys on accepted");
                end
                commit_pending = 1'b0;
                accepted_count = accepted_count + 1;
                last_accept_cycle = clock_count;
            end
            accepted_previous = accepted;
            if (guard_outputs)
                check_frozen;
        end
    end

    // Independent UART receiver samples in the middle of each bit. Back-to-
    // back ACK bytes work: after stop-bit sampling it waits for the next start.
    always begin
        @(negedge uart_tx);
        if (rst_n) begin
            if (!ack_pending)
                fail("Unsolicited ACK/telemetry or duplicate response");
            #(BIT_NS / 2.0);
            if (uart_tx !== 1'b0)
                fail("ACK UART start bit is not low");
            decoded_byte = 8'h00;
            for (decode_bit = 0; decode_bit < 8; decode_bit = decode_bit + 1) begin
                #(BIT_NS);
                decoded_byte[decode_bit] = uart_tx;
            end
            #(BIT_NS);
            if (uart_tx !== 1'b1)
                fail("ACK UART stop bit is not high");
            if (decoded_byte !== expected_ack[ack_byte_index]) begin
                $display("ACK packet %0d byte %0d: got %02x, expected %02x",
                         ack_packets + 1, ack_byte_index, decoded_byte,
                         expected_ack[ack_byte_index]);
                fail("ACK byte mismatch");
            end
            if ((ack_byte_index >= 2) && (ack_byte_index <= 14))
                ack_running_xor = ack_running_xor ^ decoded_byte;
            if (ack_byte_index == 15) begin
                if (decoded_byte !== ack_running_xor)
                    fail("ACK XOR must cover exactly bytes 2 through 14");
                ack_packets = ack_packets + 1;
                ack_byte_index = 0;
                ack_running_xor = 8'h00;
                ack_pending = 1'b0;
            end else begin
                ack_byte_index = ack_byte_index + 1;
            end
        end
    end

    task build_command;
        input [7:0] seq_value, flags_value;
        input [15:0] keys_value;
        input [7:0] velocity_value;
        input [63:0] adc_value;
        integer index;
        reg [7:0] checksum;
        begin
            command_bytes[0] = 8'ha5;
            command_bytes[1] = 8'h5a;
            command_bytes[2] = seq_value;
            command_bytes[3] = flags_value;
            command_bytes[4] = keys_value[7:0];
            command_bytes[5] = keys_value[15:8];
            command_bytes[6] = velocity_value;
            for (index = 0; index < 8; index = index + 1)
                command_bytes[7 + index] = adc_value[index*8 +: 8];
            checksum = 8'h00;
            for (index = 2; index <= 14; index = index + 1)
                checksum = checksum ^ command_bytes[index];
            command_bytes[15] = checksum;
        end
    endtask

    // Expected flags/ADC are supplied explicitly by each test; the reference
    // does not reuse DUT clamp/flag logic. Every one of the 16 bytes is checked.
    task expect_ack;
        input [7:0] seq_value, flags_value;
        input [15:0] keys_value;
        input [63:0] adc_value;
        integer index;
        reg [7:0] checksum;
        begin
            if (ack_pending || commit_pending || (ack_byte_index != 0))
                fail("Test attempted to replace an unfinished expected ACK");
            expected_ack[0] = 8'h5a;
            expected_ack[1] = 8'ha5;
            expected_ack[2] = 8'h08;
            expected_ack[3] = seq_value;
            expected_ack[4] = flags_value;
            expected_ack[5] = keys_value[7:0];
            expected_ack[6] = keys_value[15:8];
            for (index = 0; index < 8; index = index + 1)
                expected_ack[7 + index] = adc_value[index*8 +: 8];
            checksum = 8'h00;
            for (index = 2; index <= 14; index = index + 1)
                checksum = checksum ^ expected_ack[index];
            expected_ack[15] = checksum;
            ack_target = ack_packets + 1;
            ack_running_xor = 8'h00;
            ack_pending = 1'b1;
            commit_flags = flags_value & 8'h07;
            commit_seq = seq_value;
            commit_keys = keys_value;
            commit_adc = adc_value;
            commit_velocity = command_bytes[6];
            commit_pending = 1'b1;
        end
    endtask

    task send_uart_byte;
        input [7:0] value;
        input good_stop;
        integer bit_index;
        begin
            @(negedge clk);
            uart_rx = 1'b0;
            #(BIT_NS);
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                uart_rx = value[bit_index];
                #(BIT_NS);
            end
            uart_rx = good_stop;
            #(BIT_NS);
            if (!good_stop) begin
                // The invalid stop is low for a complete bit, then release
                // the line long enough for a framing-error receiver to recover.
                uart_rx = 1'b1;
                #(BIT_NS);
            end
        end
    endtask

    task send_range;
        input integer first_byte, last_byte;
        integer index;
        begin
            for (index = first_byte; index <= last_byte; index = index + 1)
                send_uart_byte(command_bytes[index], 1'b1);
        end
    endtask

    task send_valid_command;
        integer previous_count;
        begin
            previous_count = accepted_count;
            freeze_outputs;
            send_range(0, 14); // No output may change before the checksum byte.
            check_frozen;
            guard_outputs = 1'b0;
            send_uart_byte(command_bytes[15], 1'b1);
            // Allow ordinary RX synchronizer/parser pipelines to propagate.
            repeat (4) @(posedge clk);
            #2;
            if (commit_pending || (accepted_count != previous_count + 1))
                fail("Valid complete command did not generate exactly one accepted pulse");
        end
    endtask

    task wait_for_ack;
        integer elapsed;
        begin
            elapsed = 0;
            while (ack_pending && (elapsed < ACK_WAIT_CLKS)) begin
                @(posedge clk);
                #2;
                elapsed = elapsed + 1;
            end
            if (ack_pending || (ack_packets != ack_target))
                fail("Missing or incomplete 16-byte ACK");
            // Let the last stop bit and a registered TX pipeline finish before
            // beginning the next host command (the host waits for each ACK).
            repeat (2 * BIT_CLKS + 8) @(posedge clk);
            #2;
            if (uart_tx !== 1'b1)
                fail("TX did not return to idle high after ACK");
        end
    endtask

    task check_quiet;
        integer before_ack_count;
        begin
            before_ack_count = ack_packets;
            repeat (12 * BIT_CLKS) @(posedge clk);
            #2;
            check_frozen;
            if (ack_pending || (ack_packets != before_ack_count) ||
                (uart_tx !== 1'b1))
                fail("Rejected command generated a response");
        end
    endtask

    task check_active_state;
        input expected_zero, expected_park;
        input [15:0] expected_keys;
        input [7:0] expected_velocity;
        input [63:0] expected_adc;
        input [7:0] expected_seq;
        input integer expected_accepts;
        begin
            #2;
            if ((remote_active !== 1'b1) ||
                (zero_mode !== expected_zero) || (park_i2c !== expected_park) ||
                (virtual_keys !== expected_keys) ||
                (velocity !== expected_velocity) || (virtual_adc !== expected_adc) ||
                (last_seq !== expected_seq) || (accepted_count != expected_accepts))
                fail("Committed active command state does not match the packet");
        end
    endtask

    task check_inactive_state;
        input [7:0] expected_seq;
        input integer expected_accepts;
        begin
            #2;
            // Disabled/watchdog semantics specify these four control outputs;
            // velocity and unused virtual ADC need not be cleared on exit.
            if ((remote_active !== 1'b0) || (zero_mode !== 1'b0) ||
                (park_i2c !== 1'b0) || (virtual_keys !== 16'h0000) ||
                (last_seq !== expected_seq) || (accepted_count != expected_accepts))
                fail("Exit did not clear remote/zero/park/keys or changed sequence accounting");
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        uart_rx = 1'b1;
        physical_keys = 16'h1357;
        physical_adc = {16'hf0f0, 16'h0033, 16'h4455, 16'h6677};
        status_flags = 8'hdd;
        ack_pending = 1'b0;
        ack_packets = 0;
        ack_byte_index = 0;
        ack_target = 0;
        ack_running_xor = 8'h00;
        clock_count = 0;
        accepted_count = 0;
        last_accept_cycle = -1;
        accepted_previous = 1'b0;
        commit_pending = 1'b0;
        guard_outputs = 1'b0;

        repeat (8) @(posedge clk);
        #2;
        if ((uart_tx !== 1'b1) || (remote_active !== 1'b0) ||
            (zero_mode !== 1'b0) || (park_i2c !== 1'b0) ||
            (virtual_keys !== 16'h0000) || (accepted !== 1'b0))
            fail("Reset must leave TX idle high and remote control disabled");
        @(negedge clk);
        rst_n = 1'b1;
        repeat (12) @(posedge clk);
        #2;
        if ((remote_active !== 1'b0) || (ack_packets != 0) ||
            (uart_tx !== 1'b1) || (accepted_count != 0))
            fail("Reset release automatically entered remote mode or sent data");

        $display("TEST valid command, atomic update, complete ACK and status mask");
        build_command(8'h10, 8'h07, 16'ha55a, 8'h64,
                      {16'd26400, 16'd26399, 16'd1024, 16'd0});
        expect_ack(8'h10, 8'hdf, 16'ha55a,
                   {16'd26400, 16'd26399, 16'd1024, 16'd0});
        send_valid_command;
        check_active_state(1'b1, 1'b1, 16'ha55a, 8'h64,
                           {16'd26400, 16'd26399, 16'd1024, 16'd0}, 8'h10, 1);
        wait_for_ack;

        $display("TEST bad XOR: no ACK and no state/sequence change");
        build_command(8'h11, 8'h01, 16'hffff, 8'h22,
                      {16'd11, 16'd22, 16'd33, 16'd44});
        command_bytes[15] = command_bytes[15] ^ 8'h01;
        freeze_outputs;
        send_range(0, 15);
        check_quiet;

        $display("TEST illegal flag bit 7 with correct XOR: reject entire packet");
        build_command(8'h12, 8'h81, 16'h0001, 8'h23,
                      {16'd55, 16'd66, 16'd77, 16'd88});
        freeze_outputs;
        send_range(0, 15);
        check_quiet;

        $display("TEST bad final stop bit: correct checksum must not commit");
        build_command(8'h13, 8'h01, 16'h0010, 8'h24,
                      {16'd100, 16'd200, 16'd300, 16'd400});
        freeze_outputs;
        send_range(0, 14);
        send_uart_byte(command_bytes[15], 1'b0);
        check_quiet;

        $display("TEST recovery after checksum, flag and UART framing errors");
        status_flags = 8'ha7;
        build_command(8'h14, 8'h01, 16'h0003, 8'h33,
                      {16'd42, 16'd2, 16'd1, 16'd0});
        expect_ack(8'h14, 8'ha1, 16'h0003,
                   {16'd42, 16'd2, 16'd1, 16'd0});
        send_valid_command;
        check_active_state(1'b0, 1'b0, 16'h0003, 8'h33,
                           {16'd42, 16'd2, 16'd1, 16'd0}, 8'h14, 2);
        wait_for_ack;

        $display("TEST incomplete packet, 20 ms fragment expiry and stale suffix");
        build_command(8'h15, 8'h07, 16'hffff, 8'hee,
                      {16'h0404, 16'h0303, 16'h0202, 16'h0101});
        freeze_outputs;
        send_range(0, 6);
        repeat (FRAGMENT_CLKS + 20) @(posedge clk);
        #2;
        check_frozen;
        if ((ack_packets != 2) || (uart_tx !== 1'b1))
            fail("Incomplete packet generated an ACK");
        send_range(7, 15); // Cannot complete a packet after its fragment expiry.
        check_quiet;

        $display("TEST valid header/packet recovery after fragment timeout");
        send_uart_byte(8'h00, 1'b1); // Noise also clears a possible lone A5 tail.
        status_flags = 8'h57;
        build_command(8'h16, 8'h05, 16'h8001, 8'h44,
                      {16'd100, 16'd200, 16'd300, 16'd400});
        expect_ack(8'h16, 8'h55, 16'h8001,
                   {16'd100, 16'd200, 16'd300, 16'd400});
        send_valid_command;
        check_active_state(1'b0, 1'b1, 16'h8001, 8'h44,
                           {16'd100, 16'd200, 16'd300, 16'd400}, 8'h16, 3);
        wait_for_ack;

        $display("TEST illegal flag bit 3 with correct XOR: reject entire packet");
        build_command(8'he1, 8'h09, 16'hffff, 8'h99,
                      {16'd90, 16'd80, 16'd70, 16'd60});
        freeze_outputs;
        send_range(0, 15);
        check_quiet;

        $display("TEST unsigned ADC clamp: 26401, FFFF, 26400 boundary, 8000");
        status_flags = 8'h3b;
        build_command(8'h17, 8'h07, 16'h5a81, 8'hff,
                      {16'h8000, 16'd26400, 16'hffff, 16'd26401});
        expect_ack(8'h17, 8'h3f, 16'h5a81,
                   {16'd26400, 16'd26400, 16'd26400, 16'd26400});
        send_valid_command;
        check_active_state(1'b1, 1'b1, 16'h5a81, 8'hff,
                           {16'd26400, 16'd26400, 16'd26400, 16'd26400}, 8'h17, 4);
        wait_for_ack;

        // Split reserved-bit cases across valid commands so these rejection
        // assertions finish before the separate valid-packet watchdog expires.
        for (reserved_flag_bit = 4; reserved_flag_bit <= 6;
             reserved_flag_bit = reserved_flag_bit + 1) begin
            $display("TEST illegal flag bit %0d with correct XOR", reserved_flag_bit);
            build_command(8'he0 + reserved_flag_bit,
                          8'h01 | (8'h01 << reserved_flag_bit),
                          16'h1234, 8'h88,
                          {16'd600, 16'd700, 16'd800, 16'd900});
            freeze_outputs;
            send_range(0, 15);
            check_quiet;
        end

        $display("TEST disabled clears zero/park/keys and ACK echoes physical data");
        physical_keys = 16'hbeef;
        physical_adc = {16'h1234, 16'hf123, 16'hffff, 16'h0000};
        status_flags = 8'hc7;
        build_command(8'h18, 8'h06, 16'hffff, 8'h66,
                      {16'd1000, 16'd26401, 16'd0, 16'hffff});
        expect_ack(8'h18, 8'hc0, 16'hbeef,
                   {16'h1234, 16'hf123, 16'hffff, 16'h0000});
        send_valid_command;
        check_inactive_state(8'h18, 5);
        wait_for_ack;

        $display("TEST physical ADC/key/status changes do not emit telemetry");
        freeze_outputs;
        physical_keys = 16'h4321;
        physical_adc = {16'd1, 16'd2, 16'd3, 16'd4};
        status_flags = 8'hff;
        repeat (40 * BIT_CLKS) @(posedge clk);
        #2;
        check_quiet;

        $display("TEST watchdog: a bad checksum near expiry does not refresh it");
        status_flags = 8'h65;
        build_command(8'h19, 8'h07, 16'hf00f, 8'h33,
                      {16'd26400, 16'd4096, 16'd2048, 16'd1024});
        expect_ack(8'h19, 8'h67, 16'hf00f,
                   {16'd26400, 16'd4096, 16'd2048, 16'd1024});
        send_valid_command;
        check_active_state(1'b1, 1'b1, 16'hf00f, 8'h33,
                           {16'd26400, 16'd4096, 16'd2048, 16'd1024}, 8'h19, 6);
        wait_for_ack;
        freeze_outputs;
        while ((clock_count - last_accept_cycle) <
               (TIMEOUT_CYCLES - COMMAND_CLKS - 200)) begin
            @(posedge clk);
            #2;
        end
        build_command(8'h1a, 8'h07, 16'hffff, 8'h77,
                      {16'd7, 16'd8, 16'd9, 16'd10});
        command_bytes[15] = command_bytes[15] ^ 8'h80;
        send_range(0, 15);
        #2;
        check_frozen;
        guard_outputs = 1'b0;
        while ((clock_count - last_accept_cycle) < TIMEOUT_CYCLES - 2) begin
            if (remote_active !== 1'b1)
                fail("Watchdog expired before the configured valid-packet interval");
            @(posedge clk);
            #2;
        end
        while ((clock_count - last_accept_cycle) < TIMEOUT_CYCLES + 8) begin
            @(posedge clk);
            #2;
        end
        check_inactive_state(8'h19, 6);
        if (ack_pending || (ack_packets != 6) || (uart_tx !== 1'b1))
            fail("Bad checksum or watchdog exit generated an ACK");

        $display("TEST complete valid command recovers after watchdog exit");
        status_flags = 8'h83;
        build_command(8'h1b, 8'h03, 16'h0020, 8'h01,
                      {16'd5, 16'd4, 16'd3, 16'd2});
        expect_ack(8'h1b, 8'h83, 16'h0020,
                   {16'd5, 16'd4, 16'd3, 16'd2});
        send_valid_command;
        check_active_state(1'b1, 1'b0, 16'h0020, 8'h01,
                           {16'd5, 16'd4, 16'd3, 16'd2}, 8'h1b, 7);
        wait_for_ack;
        final_accepts = accepted_count;
        final_acks = ack_packets;

        $display("TEST reset again: TX idle high, no automatic remote entry/ACK");
        guard_outputs = 1'b0;
        reset_ack_count = ack_packets;
        @(negedge clk);
        rst_n = 1'b0;
        uart_rx = 1'b1;
        repeat (8) @(posedge clk);
        #2;
        if ((uart_tx !== 1'b1) || (remote_active !== 1'b0) ||
            (zero_mode !== 1'b0) || (park_i2c !== 1'b0) ||
            (virtual_keys !== 16'h0000) || (accepted !== 1'b0))
            fail("Second reset did not clear remote control and leave TX high");
        @(negedge clk);
        rst_n = 1'b1;
        repeat (20 * BIT_CLKS) @(posedge clk);
        #2;
        if ((remote_active !== 1'b0) || (zero_mode !== 1'b0) ||
            (park_i2c !== 1'b0) || (virtual_keys !== 16'h0000) ||
            (accepted_count != 0) || ack_pending ||
            (ack_packets != reset_ack_count) || (uart_tx !== 1'b1))
            fail("Reset release generated a command/ACK or entered remote mode");
        if ((final_accepts != 7) || (final_acks != 7))
            fail("Final valid-command / complete-ACK counts are wrong");
        $display("REMOTE_LINK_TEST_PASS");
        $finish;
    end

    // A broken receiver/transmitter or lost expected ACK must never hang CI.
    initial begin
        #(CLOCK_NS * TIMEOUT_CYCLES * 30.0);
        fail("Global simulation deadline exceeded");
    end
endmodule
