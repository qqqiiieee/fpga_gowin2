`timescale 1ns/1ps
// Compile as SystemVerilog (-g2012), with wavetable_synth.v,
// legacy_shared_synth.v, and the UNMODIFIED V008 note_table.v and
// diagnostic_frequency.v. No synthesis, hardware access, or waveform dump.
// Both engines read the same V008 stress wave. The new 16-bank ROM may
// report surplus words when reading the original 32-bank file; its first
// 16 banks are precisely the legacy soft banks used by color=0.
module tb_synth_equivalence;
    localparam NUM_VOICES = 32;
    localparam TABLE_BITS = 10;
    localparam FRAME_CLOCKS = 288;
    localparam DONE_CLOCK = NUM_VOICES*8 + 4;
    localparam TOTAL_FRAMES = 3968;
    localparam RELEASE_FRAME = 640;
    localparam STRESS_WAVE =
        "fixtures/pressure_wave.hex";

    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n, fs_tick;
    reg [NUM_VOICES-1:0] gate, retrigger;
    reg [NUM_VOICES*7-1:0] note_bus;
    reg [NUM_VOICES*8-1:0] vel_bus;
    reg [NUM_VOICES*4-1:0] timbre_bus;
    reg signed [8:0] pitch;
    wire [15:0] old_sample, new_sample;
    wire old_done, new_done, old_overrun, new_overrun;
    wire [NUM_VOICES-1:0] old_busy, new_busy;

    legacy_shared_synth #(
        .NUM_VOICES(NUM_VOICES), .TABLE_BITS(TABLE_BITS),
        .ONE_SHOT(0), .FILE(STRESS_WAVE)
    ) reference_engine (
        .clk(clk), .rst_n(rst_n), .fs_tick(fs_tick), .diagnostic(1'b0),
        .gate(gate), .retrigger(retrigger), .note_bus(note_bus),
        .vel_bus(vel_bus), .timbre_bus(timbre_bus), .pitch(pitch),
        .color(8'd0), .sample(old_sample), .frame_done(old_done),
        .overrun(old_overrun), .voice_busy(old_busy)
    );

    wavetable_synth #(
        .NUM_VOICES(NUM_VOICES), .TABLE_BITS(TABLE_BITS),
        .FILE("src/timbre_soft.hex")
    ) new_engine (
        .clk(clk), .rst_n(rst_n), .fs_tick(fs_tick), .test_mode(1'b0), .gate(gate),
        .retrigger(retrigger), .note_bus(note_bus), .vel_bus(vel_bus),
        .timbre_bus(timbre_bus), .pitch(pitch), .sample(new_sample),
        .frame_done(new_done), .overrun(new_overrun), .voice_busy(new_busy)
    );

    integer frame, cycle, k, voice_number, epoch, tone, velocity_value;
    integer consumed_voice, completed_frames, checked_clocks;
    integer nonzero_frames, tail_frames, retrigger_resets;
    integer retrigger_effects, boundary_reads, phase_wraps, snapshot_changes;
    integer late_retrigger_resets;
    reg [NUM_VOICES-1:0] snapshot_gate, previous_frame_gate;
    reg [NUM_VOICES*7-1:0] snapshot_notes;
    reg [NUM_VOICES*8-1:0] snapshot_velocities;
    reg [NUM_VOICES*4-1:0] snapshot_timbres;
    reg [NUM_VOICES-1:0] expected_pending, pending_before_edge;
    reg [NUM_VOICES-1:0] late_trigger_waiting;
    reg [NUM_VOICES-1:0] voices_seen, gate_rises, gate_falls, tail_voices;
    reg [NUM_VOICES-1:0] before_triggers, at_triggers, after_triggers;
    reg [15:0] voice_timbres_seen [0:NUM_VOICES-1];
    reg [255:0] velocities_seen;
    reg [127:0] notes_seen;
    reg positive_pitch_seen, negative_pitch_seen, zero_pitch_seen;
    reg positive_pcm_seen, negative_pcm_seen, all_voices_busy_seen;
    reg address_zero_seen, fraction_zero_seen, fraction_255_seen;
    reg [23:0] phase_before_edge;
    reg [7:0] envelope_before_edge;
    reg [6:0] previous_note_before_edge;
    reg expected_done;

    function integer test_velocity;
        input integer index;
        begin
            case (index % 9)
                0: test_velocity = 0;
                1: test_velocity = 1;
                2: test_velocity = 2;
                3: test_velocity = 31;
                4: test_velocity = 63;
                5: test_velocity = 64;
                6: test_velocity = 127;
                7: test_velocity = 192;
                default: test_velocity = 255;
            endcase
        end
    endfunction

    // Only phases are poked, on a falling edge before the next frame.
    // No samples, ROM values, envelopes, valid flags, or outputs are forced.
    // TABLE_BITS=10: address [23:14], fraction [13:6], residual [5:0].
    task seed_phase_boundaries;
        integer v;
        reg [23:0] phase_seed;
        begin
            for (v=0; v<NUM_VOICES; v=v+1) begin
                case (v % 8)
                    0: phase_seed = 24'h000000;
                    1: phase_seed = 24'h00003f;
                    2: phase_seed = 24'h000040;
                    3: phase_seed = 24'hffbfff;
                    4: phase_seed = 24'hffc000;
                    5: phase_seed = 24'hffc03f;
                    6: phase_seed = 24'hffffc0;
                    default: phase_seed = 24'hffffff;
                endcase
                reference_engine.phases[v] = phase_seed;
                new_engine.phases[v] = phase_seed;
            end
        end
    endtask

    task configure_frame;
        input integer f;
        integer v, n;
        begin
            retrigger = 0;
            // Four frames per isolated voice, then all 32 simultaneously.
            if (f < 128) gate = 32'h00000001 << (f/4);
            else if (f < RELEASE_FRAME) gate = 32'hffffffff;
            else gate = 0;
            epoch = (f >= 128 && f < 256) ? (f-128)/8 : 0;
            for (v=0; v<NUM_VOICES; v=v+1) begin
                n = 21 + ((v*7) % 88);
                if (v == 31) n = 108;
                if (f >= 252 && f < 256) n = 21 + ((n-20) % 88);
                if (f == 140 && v == 7) n = 108;
                note_bus[v*7 +: 7] = n;
                tone = (v + epoch) % 16;
                timbre_bus[v*4 +: 4] = tone;
                velocity_value = test_velocity(v + epoch);
                if (f >= 256) begin
                    // Slow attacks are bounded so every release finishes
                    // within this run; other voices still exercise 255.
                    velocity_value = (v % 2) ? 255 : 192;
                    if (tone == 0 || tone == 1 || tone == 8)
                        velocity_value = (v % 2) ? 127 : 64;
                end
                vel_bus[v*8 +: 8] = velocity_value;
            end
            case ((f/16) % 7)
                0: pitch = 9'sd0;
                1: pitch = 9'sd255;
                2: pitch = -9'sd256;
                3: pitch = 9'sd127;
                4: pitch = -9'sd127;
                5: pitch = 9'sd64;
                default: pitch = -9'sd64;
            endcase
            if (f == 136 || f == 168 || f == 200 || f == 232 ||
                f == 256 || f == 320) seed_phase_boundaries;
        end
    endtask

    task drive_cycle;
        input integer f, c;
        integer target;
        begin
            fs_tick = (c == 0);
            retrigger = 0;
            // Slot zero for voice v is tick+1+8*v. Each class visits
            // every voice, with a one-clock pulse and unchanged note.
            if (f >= 144 && f < 176) begin
                target = f-144;
                if (c == 8*target) begin
                    retrigger[target] = 1;
                    before_triggers[target] = 1;
                end
            end
            if (f >= 176 && f < 208) begin
                target = f-176;
                if (c == 1+8*target) begin
                    retrigger[target] = 1;
                    at_triggers[target] = 1;
                    late_trigger_waiting[target] = 1;
                end
            end
            if (f >= 208 && f < 240) begin
                target = f-208;
                if (c == 2+8*target) begin
                    retrigger[target] = 1;
                    after_triggers[target] = 1;
                    late_trigger_waiting[target] = 1;
                end
            end
            // Whole-chord same-note pulses: at the tick, early, middle,
            // last-voice slot zero, and after the frame has completed.
            if ((f == 264 && c == 0) || (f == 272 && c == 2) ||
                (f == 280 && c == 129) || (f == 284 && c == 249) ||
                (f == 288 && c == 270)) retrigger = 32'hffffffff;

            // Live controls change after the latch point. Both engines
            // must finish using the captured frame, including its pitch.
            if ((f == 132 || f == 156 || f == 220) && c == 100) begin
                gate = 0;
                note_bus = 0;
                vel_bus = 0;
                timbre_bus = {NUM_VOICES{4'hf}};
                pitch = -9'sd256;
                snapshot_changes = snapshot_changes + 1;
            end
            if (c == 0) begin
                snapshot_gate = gate;
                snapshot_notes = note_bus;
                snapshot_velocities = vel_bus;
                snapshot_timbres = timbre_bus;
                gate_rises = gate_rises | (gate & ~previous_frame_gate);
                gate_falls = gate_falls | (~gate & previous_frame_gate);
                previous_frame_gate = gate;
                if (gate != 0) begin
                    if (pitch > 0) positive_pitch_seen = 1;
                    if (pitch < 0) negative_pitch_seen = 1;
                    if (pitch == 0) zero_pitch_seen = 1;
                end
            end
            consumed_voice = -1;
            pending_before_edge = expected_pending;
            if (c >= 1 && c <= 1+8*(NUM_VOICES-1) && (c-1)%8 == 0) begin
                consumed_voice = (c-1)/8;
                phase_before_edge = reference_engine.phases[consumed_voice];
                envelope_before_edge = reference_engine.envelopes[consumed_voice];
                previous_note_before_edge = reference_engine.previous_notes[consumed_voice];
                expected_pending[consumed_voice] = 0;
            end
            // Crucial legacy rule: a pulse on the consume edge survives
            // for the next frame, because OR(retrigger) follows clear.
            expected_pending = expected_pending | retrigger;
        end
    endtask

    task check_cycle;
        input integer f, c;
        integer v;
        begin
            checked_clocks = checked_clocks + 1;
            expected_done = (c == DONE_CLOCK);
            if (old_done !== new_done || old_done !== expected_done)
                $fatal(1, "SYNTH_EQUIVALENCE_TEST_FAIL done frame=%0d cycle=%0d old=%b new=%b expected=%b",
                       f, c, old_done, new_done, expected_done);
            // Case inequality checks all 16 two's-complement bits and X/Z;
            // every clock is checked, including retained PCM between done.
            if (old_sample !== new_sample || (^old_sample) === 1'bx)
                $fatal(1, "SYNTH_EQUIVALENCE_TEST_FAIL PCM frame=%0d cycle=%0d old=%h (%0d) new=%h (%0d)",
                       f, c, old_sample, $signed(old_sample), new_sample, $signed(new_sample));
            if (old_busy !== new_busy || (^old_busy) === 1'bx)
                $fatal(1, "SYNTH_EQUIVALENCE_TEST_FAIL busy frame=%0d cycle=%0d old=%h new=%h",
                       f, c, old_busy, new_busy);
            if (old_overrun !== new_overrun || old_overrun !== 1'b0)
                $fatal(1, "SYNTH_EQUIVALENCE_TEST_FAIL overrun frame=%0d cycle=%0d old=%b new=%b",
                       f, c, old_overrun, new_overrun);
            if (reference_engine.pending_triggers !== expected_pending)
                $fatal(1, "SYNTH_EQUIVALENCE_TEST_FAIL trigger scoreboard frame=%0d cycle=%0d", f, c);
            if (old_busy == 32'hffffffff) all_voices_busy_seen = 1;

            if (consumed_voice >= 0) begin
                v = consumed_voice;
                if (snapshot_gate[v]) begin
                    voices_seen[v] = 1;
                    voice_timbres_seen[v][snapshot_timbres[v*4 +: 4]] = 1;
                    velocities_seen[snapshot_velocities[v*8 +: 8]] = 1;
                    notes_seen[snapshot_notes[v*7 +: 7]] = 1;
                    if (phase_before_edge[23:14] == 0) address_zero_seen = 1;
                    if (phase_before_edge[13:6] == 0) fraction_zero_seen = 1;
                    if (phase_before_edge[13:6] == 255) fraction_255_seen = 1;
                    // Nonzero envelopes ensure the 1023->0 interpolation
                    // boundary contributes through real PCM arithmetic.
                    if (phase_before_edge[23:14] == 1023 && reference_engine.envelopes[v] != 0)
                        boundary_reads = boundary_reads + 1;
                    if (reference_engine.phases[v] < phase_before_edge)
                        phase_wraps = phase_wraps + 1;
                    if (pending_before_edge[v]) begin
                        if (reference_engine.envelopes[v] !== 8'd0 || reference_engine.states[v] !== 3'd1)
                            $fatal(1, "SYNTH_EQUIVALENCE_TEST_FAIL retrigger did not restart voice=%0d frame=%0d", v, f);
                        retrigger_resets = retrigger_resets + 1;
                        if (envelope_before_edge != 0 && previous_note_before_edge == snapshot_notes[v*7 +: 7])
                            retrigger_effects = retrigger_effects + 1;
                        if (late_trigger_waiting[v]) begin
                            late_retrigger_resets = late_retrigger_resets + 1;
                            late_trigger_waiting[v] = 0;
                        end
                    end
                end
                if (f >= RELEASE_FRAME && old_busy[v]) tail_voices[v] = 1;
            end
            if (old_done) begin
                completed_frames = completed_frames + 1;
                if (old_sample != 0) nonzero_frames = nonzero_frames + 1;
                if ($signed(old_sample) > 0) positive_pcm_seen = 1;
                if ($signed(old_sample) < 0) negative_pcm_seen = 1;
                if (f >= RELEASE_FRAME && old_sample != 0) tail_frames = tail_frames + 1;
                if (f >= TOTAL_FRAMES-32 && (old_busy !== 0 || old_sample !== 0))
                    $fatal(1, "SYNTH_EQUIVALENCE_TEST_FAIL release did not settle frame=%0d busy=%h PCM=%h",
                           f, old_busy, old_sample);
            end
        end
    endtask

    initial begin
        rst_n=0; fs_tick=0; gate=0; retrigger=0;
        note_bus=0; vel_bus=0; timbre_bus=0; pitch=0;
        completed_frames=0; checked_clocks=0; nonzero_frames=0;
        tail_frames=0; retrigger_resets=0; retrigger_effects=0;
        boundary_reads=0; phase_wraps=0; snapshot_changes=0;
        late_retrigger_resets=0; consumed_voice=-1;
        snapshot_gate=0; snapshot_notes=0; snapshot_velocities=0;
        snapshot_timbres=0; previous_frame_gate=0;
        expected_pending=0; pending_before_edge=0; late_trigger_waiting=0;
        voices_seen=0; gate_rises=0; gate_falls=0; tail_voices=0;
        before_triggers=0; at_triggers=0; after_triggers=0;
        velocities_seen=0; notes_seen=0;
        positive_pitch_seen=0; negative_pitch_seen=0; zero_pitch_seen=0;
        positive_pcm_seen=0; negative_pcm_seen=0; all_voices_busy_seen=0;
        address_zero_seen=0; fraction_zero_seen=0; fraction_255_seen=0;
        for (k=0; k<NUM_VOICES; k=k+1) voice_timbres_seen[k]=0;
        repeat (4) @(negedge clk);
        if (old_sample !== 0 || new_sample !== 0 || old_busy !== 0 ||
            new_busy !== 0 || old_done !== 0 || new_done !== 0 ||
            old_overrun !== 0 || new_overrun !== 0)
            $fatal(1, "SYNTH_EQUIVALENCE_TEST_FAIL reset outputs");
        rst_n = 1;
        for (frame=0; frame<TOTAL_FRAMES; frame=frame+1) begin
            configure_frame(frame);
            for (cycle=0; cycle<FRAME_CLOCKS; cycle=cycle+1) begin
                drive_cycle(frame, cycle);
                @(posedge clk);
                #1; // Observe all nonblocking assignments, without races.
                check_cycle(frame, cycle);
                @(negedge clk);
            end
        end
        fs_tick=0; retrigger=0;
        if (completed_frames != TOTAL_FRAMES || checked_clocks != TOTAL_FRAMES*FRAME_CLOCKS)
            $fatal(1, "SYNTH_EQUIVALENCE_TEST_FAIL incomplete run");
        if (voices_seen !== 32'hffffffff || gate_rises !== 32'hffffffff ||
            gate_falls !== 32'hffffffff || tail_voices !== 32'hffffffff || !all_voices_busy_seen)
            $fatal(1, "SYNTH_EQUIVALENCE_TEST_FAIL voice/gate/tail coverage");
        for (k=0; k<NUM_VOICES; k=k+1)
            if (voice_timbres_seen[k] !== 16'hffff)
                $fatal(1, "SYNTH_EQUIVALENCE_TEST_FAIL timbre coverage voice=%0d mask=%h", k, voice_timbres_seen[k]);
        if (!velocities_seen[0] || !velocities_seen[1] || !velocities_seen[2] ||
            !velocities_seen[31] || !velocities_seen[63] || !velocities_seen[64] ||
            !velocities_seen[127] || !velocities_seen[192] || !velocities_seen[255] ||
            !notes_seen[21] || !notes_seen[108] || !positive_pitch_seen ||
            !negative_pitch_seen || !zero_pitch_seen)
            $fatal(1, "SYNTH_EQUIVALENCE_TEST_FAIL note/velocity/pitch coverage");
        if (before_triggers !== 32'hffffffff || at_triggers !== 32'hffffffff ||
            after_triggers !== 32'hffffffff || late_trigger_waiting !== 0 ||
            late_retrigger_resets < 64 || retrigger_resets < 96 || retrigger_effects < 16)
            $fatal(1, "SYNTH_EQUIVALENCE_TEST_FAIL retrigger coverage resets=%0d effects=%0d late=%0d",
                   retrigger_resets, retrigger_effects, late_retrigger_resets);
        if (!address_zero_seen || !fraction_zero_seen || !fraction_255_seen ||
            boundary_reads < 16 || phase_wraps < 16 || snapshot_changes != 3)
            $fatal(1, "SYNTH_EQUIVALENCE_TEST_FAIL boundary/snapshot coverage reads=%0d wraps=%0d",
                   boundary_reads, phase_wraps);
        if (nonzero_frames < 128 || tail_frames < 128 || !positive_pcm_seen || !negative_pcm_seen)
            $fatal(1, "SYNTH_EQUIVALENCE_TEST_FAIL silent/one-polarity output active=%0d tail=%0d",
                   nonzero_frames, tail_frames);
        $display("SYNTH_EQUIVALENCE_TEST_PASS frames=%0d clocks=%0d nonzero=%0d tail=%0d retrigger=%0d effective=%0d late=%0d boundaries=%0d wraps=%0d",
                 completed_frames, checked_clocks, nonzero_frames, tail_frames,
                 retrigger_resets, retrigger_effects, late_retrigger_resets, boundary_reads, phase_wraps);
        $finish;
    end

    // Bounded simulated duration: 1,142,784 clocks, no VCD or per-frame log.
    initial begin
        #12000000;
        $fatal(1, "SYNTH_EQUIVALENCE_TEST_FAIL simulation watchdog");
    end
endmodule
