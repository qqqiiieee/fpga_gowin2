`timescale 1ns/1ps
// Candidate-local tests. Run scripts/run_packed_rom_validation.py, which
// compiles frozen V015 with only its module name changed. Tests cover both
// COMPACT_ROM=1 with verified half files and default generic FILE behavior.
module tb_packed_rom_equivalence;
    localparam NUM_VOICES = 32;
    localparam TABLE_BITS = 10;
    localparam FRAME_CLOCKS = 288;
    localparam DONE_CLOCK = NUM_VOICES*8 + 4;
    localparam TOTAL_FRAMES = 3968;
    localparam RELEASE_FRAME = 640;

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
    wire [NUM_VOICES-1:0] old_audible, new_audible;

    wavetable_synth_v015_reference #(
        .NUM_VOICES(NUM_VOICES), .TABLE_BITS(TABLE_BITS),
        .FILE("src/timbre_soft.hex")
    ) reference_engine (
        .clk(clk), .rst_n(rst_n), .fs_tick(fs_tick), .test_mode(1'b0),
        .gate(gate), .retrigger(retrigger), .note_bus(note_bus),
        .vel_bus(vel_bus), .timbre_bus(timbre_bus), .pitch(pitch),
        .sample(old_sample), .frame_done(old_done), .overrun(old_overrun),
        .voice_busy(old_busy), .voice_audible(old_audible)
    );

    wavetable_synth #(
        .NUM_VOICES(NUM_VOICES), .TABLE_BITS(TABLE_BITS),
        .FILE("src/timbre_soft.hex"), .COMPACT_ROM(1)
    ) new_engine (
        .clk(clk), .rst_n(rst_n), .fs_tick(fs_tick), .test_mode(1'b0), .gate(gate),
        .retrigger(retrigger), .note_bus(note_bus), .vel_bus(vel_bus),
        .timbre_bus(timbre_bus), .pitch(pitch), .sample(new_sample),
        .frame_done(new_done), .overrun(new_overrun), .voice_busy(new_busy), .voice_audible(new_audible)
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
                $fatal(1, "PACKED_ROM_EQUIVALENCE_TEST_FAIL done frame=%0d cycle=%0d old=%b new=%b expected=%b",
                       f, c, old_done, new_done, expected_done);
            // Case inequality checks all 16 two's-complement bits and X/Z;
            // every clock is checked, including retained PCM between done.
            if (old_sample !== new_sample || (^old_sample) === 1'bx)
                $fatal(1, "PACKED_ROM_EQUIVALENCE_TEST_FAIL PCM frame=%0d cycle=%0d old=%h (%0d) new=%h (%0d)",
                       f, c, old_sample, $signed(old_sample), new_sample, $signed(new_sample));
            if (reference_engine.rom_q !== new_engine.rom_q || reference_engine.sine_q !== new_engine.sine_q)
                $fatal(1, "PACKED_ROM_EQUIVALENCE_TEST_FAIL ROM latency frame=%0d cycle=%0d", f, c);
            if (old_audible !== new_audible || (^old_audible) === 1'bx)
                $fatal(1, "PACKED_ROM_EQUIVALENCE_TEST_FAIL audible frame=%0d cycle=%0d", f, c);
            if ($signed(reference_engine.accumulator) !== $signed(new_engine.accumulator))
                $fatal(1, "PACKED_ROM_EQUIVALENCE_TEST_FAIL accumulator frame=%0d cycle=%0d", f, c);
            if (old_busy !== new_busy || (^old_busy) === 1'bx)
                $fatal(1, "PACKED_ROM_EQUIVALENCE_TEST_FAIL busy frame=%0d cycle=%0d old=%h new=%h",
                       f, c, old_busy, new_busy);
            if (old_overrun !== new_overrun || old_overrun !== 1'b0)
                $fatal(1, "PACKED_ROM_EQUIVALENCE_TEST_FAIL overrun frame=%0d cycle=%0d old=%b new=%b",
                       f, c, old_overrun, new_overrun);
            if (reference_engine.pending_triggers !== expected_pending)
                $fatal(1, "PACKED_ROM_EQUIVALENCE_TEST_FAIL trigger scoreboard frame=%0d cycle=%0d", f, c);
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
                            $fatal(1, "PACKED_ROM_EQUIVALENCE_TEST_FAIL retrigger did not restart voice=%0d frame=%0d", v, f);
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
                    $fatal(1, "PACKED_ROM_EQUIVALENCE_TEST_FAIL release did not settle frame=%0d busy=%h PCM=%h",
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
            $fatal(1, "PACKED_ROM_EQUIVALENCE_TEST_FAIL reset outputs");
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
            $fatal(1, "PACKED_ROM_EQUIVALENCE_TEST_FAIL incomplete run");
        if (voices_seen !== 32'hffffffff || gate_rises !== 32'hffffffff ||
            gate_falls !== 32'hffffffff || tail_voices !== 32'hffffffff || !all_voices_busy_seen)
            $fatal(1, "PACKED_ROM_EQUIVALENCE_TEST_FAIL voice/gate/tail coverage");
        for (k=0; k<NUM_VOICES; k=k+1)
            if (voice_timbres_seen[k] !== 16'hffff)
                $fatal(1, "PACKED_ROM_EQUIVALENCE_TEST_FAIL timbre coverage voice=%0d mask=%h", k, voice_timbres_seen[k]);
        if (!velocities_seen[0] || !velocities_seen[1] || !velocities_seen[2] ||
            !velocities_seen[31] || !velocities_seen[63] || !velocities_seen[64] ||
            !velocities_seen[127] || !velocities_seen[192] || !velocities_seen[255] ||
            !notes_seen[21] || !notes_seen[108] || !positive_pitch_seen ||
            !negative_pitch_seen || !zero_pitch_seen)
            $fatal(1, "PACKED_ROM_EQUIVALENCE_TEST_FAIL note/velocity/pitch coverage");
        if (before_triggers !== 32'hffffffff || at_triggers !== 32'hffffffff ||
            after_triggers !== 32'hffffffff || late_trigger_waiting !== 0 ||
            late_retrigger_resets < 64 || retrigger_resets < 96 || retrigger_effects < 16)
            $fatal(1, "PACKED_ROM_EQUIVALENCE_TEST_FAIL retrigger coverage resets=%0d effects=%0d late=%0d",
                   retrigger_resets, retrigger_effects, late_retrigger_resets);
        if (!address_zero_seen || !fraction_zero_seen || !fraction_255_seen ||
            boundary_reads < 16 || phase_wraps < 16 || snapshot_changes != 3)
            $fatal(1, "PACKED_ROM_EQUIVALENCE_TEST_FAIL boundary/snapshot coverage reads=%0d wraps=%0d",
                   boundary_reads, phase_wraps);
        if (nonzero_frames < 128 || tail_frames < 128 || !positive_pcm_seen || !negative_pcm_seen)
            $fatal(1, "PACKED_ROM_EQUIVALENCE_TEST_FAIL silent/one-polarity output active=%0d tail=%0d",
                   nonzero_frames, tail_frames);
        $display("PACKED_ROM_EQUIVALENCE_TEST_PASS frames=%0d clocks=%0d nonzero=%0d tail=%0d retrigger=%0d effective=%0d late=%0d boundaries=%0d wraps=%0d",
                 completed_frames, checked_clocks, nonzero_frames, tail_frames,
                 retrigger_resets, retrigger_effects, late_retrigger_resets, boundary_reads, phase_wraps);
        $finish;
    end

    // Bounded simulated duration: 1,142,784 clocks, no VCD or per-frame log.
    initial begin
        #12000000;
        $fatal(1, "PACKED_ROM_EQUIVALENCE_TEST_FAIL simulation watchdog");
    end
endmodule

// Each case drives exactly the same inputs into baseline and optimized RTL.
// Synthetic HEX files are generated only in validation/synth_resource_agent/*.
module packed_rom_stress_case #(
    parameter N=32,
    parameter WAVE_FILE="src/timbre_soft.hex",
    parameter SINE_FILE="src/test_sine.hex",
    parameter CASE_ID=0,
    parameter COMPACT=1,
    parameter HALF_FILE="src/timbre_odd_half.hex"
)(output reg finished=0);
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=1,fs_tick=0,test_mode=0;
    reg [N-1:0] gate=0,retrigger=0;
    reg [N*7-1:0] note_bus=0;
    reg [N*8-1:0] vel_bus=0;
    reg [N*4-1:0] timbre_bus=0;
    reg signed [8:0] pitch=0;
    wire [15:0] old_sample,new_sample;
    wire old_done,new_done,old_overrun,new_overrun;
    wire [N-1:0] old_busy,new_busy,old_audible,new_audible;
    wavetable_synth_v015_reference #(.NUM_VOICES(N),.FILE(WAVE_FILE),.TEST_FILE(SINE_FILE)) reference_engine(
        .clk(clk),.rst_n(rst_n),.fs_tick(fs_tick),.test_mode(test_mode),
        .gate(gate),.retrigger(retrigger),.note_bus(note_bus),.vel_bus(vel_bus),
        .timbre_bus(timbre_bus),.pitch(pitch),.sample(old_sample),.frame_done(old_done),
        .overrun(old_overrun),.voice_busy(old_busy),.voice_audible(old_audible));
    wavetable_synth #(.NUM_VOICES(N),.FILE(WAVE_FILE),.TEST_FILE(SINE_FILE),.COMPACT_ROM(COMPACT),.PACKED_FILE(HALF_FILE)) new_engine(
        .clk(clk),.rst_n(rst_n),.fs_tick(fs_tick),.test_mode(test_mode),
        .gate(gate),.retrigger(retrigger),.note_bus(note_bus),.vel_bus(vel_bus),
        .timbre_bus(timbre_bus),.pitch(pitch),.sample(new_sample),.frame_done(new_done),
        .overrun(new_overrun),.voice_busy(new_busy),.voice_audible(new_audible));
    integer clocks=0,completions=0,nonzero=0,tail_frames=0,mode_changes=0;
    integer terms=0,max_terms=0,write_voice=-1,old_valid=0;
    integer frame,c,v,cut,positive=0,negative=0,reset_checks=0;
    reg [4:0] adsr_seen=0;
    reg [15:0] timbres_seen[0:N-1];
    reg [255:0] velocities_seen=0;
    reg [127:0] notes_seen=0;
    reg [31:0] rng=32'h6a09e667;
    reg [31:0] random_word;
    reg tick_value;
    function [31:0] random_next;
        input [31:0] x;
        reg [31:0] t;
        begin t=x^(x<<13);t=t^(t>>17);random_next=t^(t<<5);end
    endfunction
    task compare_state;
        input integer index;
        begin
            if (reference_engine.phases[index] !== new_engine.phases[index] ||
                reference_engine.envelopes[index] !== new_engine.envelopes[index] ||
                reference_engine.subdivisions[index] !== new_engine.subdivisions[index] ||
                reference_engine.states[index] !== new_engine.states[index] ||
                reference_engine.previous_notes[index] !== new_engine.previous_notes[index])
                $fatal(1,"RESOURCE_STRESS state case=%0d clock=%0d voice=%0d",CASE_ID,clocks,index);
        end
    endtask
    task compare_outputs;
        begin
            if (old_sample !== new_sample || (^old_sample) === 1'bx ||
                old_done !== new_done || old_overrun !== new_overrun ||
                old_busy !== new_busy || old_audible !== new_audible ||
                (^old_busy) === 1'bx || (^old_audible) === 1'bx)
                $fatal(1,"RESOURCE_STRESS outputs case=%0d clock=%0d PCM=%h/%h done=%b/%b busy=%h/%h",
                    CASE_ID,clocks,old_sample,new_sample,old_done,new_done,old_busy,new_busy);
            if (reference_engine.pending_triggers !== new_engine.pending_triggers ||
                reference_engine.previous_gates !== new_engine.previous_gates ||
                reference_engine.running !== new_engine.running ||
                reference_engine.voice_index !== new_engine.voice_index ||
                reference_engine.slot !== new_engine.slot ||
                {reference_engine.v0,reference_engine.v1,reference_engine.v2,reference_engine.v3} !==
                {new_engine.v0,new_engine.v1,new_engine.v2,new_engine.v3})
                $fatal(1,"RESOURCE_STRESS scheduling case=%0d clock=%0d",CASE_ID,clocks);
            if (reference_engine.rom_q !== new_engine.rom_q || reference_engine.sine_q !== new_engine.sine_q)
                $fatal(1,"PACKED_ROM_STRESS ROM latency case=%0d clock=%0d",CASE_ID,clocks);
            if ($signed(reference_engine.accumulator) !== $signed(new_engine.accumulator) ||
                $signed(reference_engine.final_sum) !== $signed(new_engine.final_sum) ||
                $signed(reference_engine.scaled) !== $signed(new_engine.scaled) ||
                $signed(reference_engine.soft_product) !== $signed(new_engine.soft_product) ||
                reference_engine.magnitude !== new_engine.magnitude ||
                reference_engine.compressed !== new_engine.compressed ||
                reference_engine.bounded !== new_engine.bounded)
                $fatal(1,"RESOURCE_STRESS arithmetic case=%0d clock=%0d accumulator=%0d/%0d product=%0d/%0d",
                    CASE_ID,clocks,$signed(reference_engine.accumulator),$signed(new_engine.accumulator),
                    $signed(reference_engine.soft_product),$signed(new_engine.soft_product));
        end
    endtask
    task step;
        input tick;
        input [N-1:0] triggers;
        begin
            fs_tick=tick;retrigger=triggers;
            write_voice=-1;
            old_valid=reference_engine.v3;
            if (reference_engine.running && reference_engine.slot==0 && !tick) begin
                write_voice=reference_engine.voice_index;
                if(reference_engine.selected_gate) begin
                    timbres_seen[write_voice][reference_engine.timbre]=1;
                    velocities_seen[reference_engine.velocity]=1;
                    notes_seen[reference_engine.selected_note]=1;
                end
            end
            if(tick) terms=0;
            else if(old_valid) terms=terms+1;
            if(terms>max_terms) max_terms=terms;
            if(terms>N+1) $fatal(1,"RESOURCE_STRESS sample count bound case=%0d terms=%0d",CASE_ID,terms);
            @(posedge clk);#1;
            clocks=clocks+1;
            compare_outputs;
            if(write_voice>=0) compare_state(write_voice);
            if(old_done) begin
                completions=completions+1;
                if(old_sample!=0) nonzero=nonzero+1;
                if($signed(old_sample)>0) positive=positive+1;
                if($signed(old_sample)<0) negative=negative+1;
                if(frame>=1792 && frame<6400 && old_sample!=0) tail_frames=tail_frames+1;
                for(v=0;v<N;v=v+1) begin
                    compare_state(v);
                    if(reference_engine.states[v]<=4) adsr_seen[reference_engine.states[v]]=1;
                end
            end
            @(negedge clk);
        end
    endtask
    task async_reset;
        begin
            fs_tick=0;retrigger=0;
            #2;rst_n=0;#1;
            compare_outputs;
            if(old_sample!==0 || old_done!==0 || old_busy!==0 || old_audible!==0 || old_overrun!==0)
                $fatal(1,"RESOURCE_STRESS asynchronous reset case=%0d",CASE_ID);
            for(v=0;v<N;v=v+1) begin
                compare_state(v);
                if(reference_engine.phases[v]!==0 || reference_engine.envelopes[v]!==0 ||
                    reference_engine.subdivisions[v]!==0 || reference_engine.states[v]!==0 ||
                    reference_engine.previous_notes[v]!==0)
                    $fatal(1,"RESOURCE_STRESS asynchronous state reset case=%0d voice=%0d",CASE_ID,v);
            end
            reset_checks=reset_checks+1;terms=0;
            repeat(2) @(negedge clk);
            rst_n=1;
        end
    endtask
    task phase_boundaries;
        integer j;
        reg [23:0] value;
        begin
            for(j=0;j<N;j=j+1) begin
                case(j%8)
                    0:value=24'h000000;
                    1:value=24'h000040;
                    2:value=24'h003fc0;
                    3:value=24'h7fffff;
                    4:value=24'hffc000;
                    5:value=24'hffc040;
                    6:value=24'hffffc0;
                    default:value=24'hffffff;
                endcase
                reference_engine.phases[j]=value;
                new_engine.phases[j]=value;
            end
        end
    endtask
    initial begin
        for(v=0;v<N;v=v+1) timbres_seen[v]=0;
        @(negedge clk);async_reset;
        for(frame=0;frame<6400;frame=frame+1) begin
            gate=(frame<1792)?{N{1'b1}}:0;
            if(frame<512) begin
                test_mode=0;
                for(v=0;v<N;v=v+1) begin
                    note_bus[v*7+:7]=(frame+v*7)%128;
                    vel_bus[v*8+:8]=(frame+v*13)%256;
                    timbre_bus[v*4+:4]=(frame/8+v)%16;
                end
            end else begin
                test_mode=(frame<1536)?1:((frame<1792)?frame[0]:0);
                for(v=0;v<N;v=v+1) begin
                    note_bus[v*7+:7]=69;
                    vel_bus[v*8+:8]=255;
                    timbre_bus[v*4+:4]=6;
                end
            end
            case(frame%3)
                0:pitch=-9'sd256;
                1:pitch=9'sd255;
                default:pitch=0;
            endcase
            if(frame>=1536 && frame<1792) mode_changes=mode_changes+1;
            if(frame==600 || frame==1000 || frame==1536 || frame==1600 || frame==1791)
                phase_boundaries;
            for(c=0;c<288;c=c+1) begin
                random_word=0;
                if(frame>=544 && frame<640) begin
                    // Before/on/after consumption, for every voice.
                    if(c==8*((frame-544)%N)+(frame-544)/N) random_word=1<<((frame-544)%N);
                end
                // Changes after latch must not change this frame's ROM mode or controls.
                if(c==100 && frame>=1536 && frame<1544) begin
                    test_mode=~test_mode;note_bus=~note_bus;vel_bus=~vel_bus;
                    timbre_bus=~timbre_bus;gate=~gate;pitch=~pitch;
                end
                step(c==0,random_word[N-1:0]);
                if(old_done !== (c==N*8+4))
                    $fatal(1,"RESOURCE_STRESS frame latency case=%0d frame=%0d cycle=%0d",CASE_ID,frame,c);
                if(old_overrun!==0) $fatal(1,"RESOURCE_STRESS legal cadence overrun case=%0d",CASE_ID);
            end
        end
        if(old_busy!==0 || old_audible!==0 || old_sample!==0 || adsr_seen!==5'b11111 ||
            positive<100 || negative<100 || tail_frames<100 ||
            velocities_seen!=={256{1'b1}} || notes_seen!=={128{1'b1}})
            $fatal(1,"RESOURCE_STRESS coverage case=%0d ADSR=%b positive=%0d negative=%0d tails=%0d",
                CASE_ID,adsr_seen,positive,negative,tail_frames);
        for(v=0;v<N;v=v+1) if(timbres_seen[v]!==16'hffff)
            $fatal(1,"RESOURCE_STRESS timbre coverage case=%0d voice=%0d",CASE_ID,v);

        // A new tick one clock after slot 7 leaves one old sample in flight.
        // Complete the new frame to exercise N+1 accumulated terms.
        gate={N{1'b1}};test_mode=1;vel_bus={N{8'hff}};
        step(1,0);
        for(c=1;c<=N*8;c=c+1) step(0,0);
        step(1,{N{1'b1}});
        for(c=1;c<288;c=c+1) step(0,0);
        if(max_terms!=N+1 || old_overrun!==1)
            $fatal(1,"RESOURCE_STRESS residual frame case=%0d max_terms=%0d",CASE_ID,max_terms);

        // Reset at every position of a frame and its output pipeline.
        for(cut=0;cut<N*8+8;cut=cut+1) begin
            async_reset;step(1,{N{1'b1}});
            for(c=0;c<cut;c=c+1) step(0,0);
        end
        async_reset;
        // Irregular fs_tick, test-mode changes, pitch and controls. No writes
        // or forces to accumulator, pipeline, envelope, ROM or PCM registers.
        for(c=0;c<80000;c=c+1) begin
            rng=random_next(rng);random_word=rng;
            tick_value=(c%521==0 || random_word[6:0]==0);
            if(c%13==0) begin
                test_mode=random_word[0];gate=random_word[N-1:0];pitch=random_word[8:0];
                for(v=0;v<N;v=v+1) begin
                    rng=random_next(rng);
                    note_bus[v*7+:7]=rng[6:0];vel_bus[v*8+:8]=rng[15:8];timbre_bus[v*4+:4]=rng[19:16];
                end
            end
            step(tick_value,random_word[N-1:0]);
        end
        $display("PACKED_ROM_STRESS_CASE_PASS case=%0d voices=%0d clocks=%0d frames=%0d nonzero=%0d tail=%0d positive=%0d negative=%0d ADSR=%b resets=%0d max_terms=%0d",
            CASE_ID,N,clocks,completions,nonzero,tail_frames,positive,negative,adsr_seen,reset_checks,max_terms);
        finished=1;
    end
endmodule

module tb_packed_rom_stress;
    wire a,b,c;
    packed_rom_stress_case #(.CASE_ID(0)) actual_wave(a);
    // Default COMPACT_ROM=0 must retain non-odd arbitrary FILE support. A
    // nonexistent packed file also proves this branch does not read it.
    packed_rom_stress_case #(.CASE_ID(1),.COMPACT(0),.HALF_FILE("intentionally_absent.hex"),
        .WAVE_FILE("stress_wave.hex"),.SINE_FILE("stress_sine.hex")) generic_wave(b);
    packed_rom_stress_case #(.CASE_ID(2),.WAVE_FILE("full_range_odd.hex"),
        .HALF_FILE("full_range_odd_half.hex"),.SINE_FILE("stress_sine.hex")) full_range_odd(c);
    initial begin
        wait(a && b && c);
        $display("PACKED_ROM_STRESS_TEST_PASS actual_and_full_range_odd_and_generic_ROMs");
        $finish;
    end
    initial begin
        #50000000;
        $fatal(1,"PACKED_ROM_STRESS_TEST_FAIL watchdog");
    end
endmodule

// Exhaustive lookup and exact one-clock latency, independently of PCM.
// Hierarchical address writes happen with running=0, at falling clock edges.
module tb_packed_rom_lookup;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0;
    reg [15:0] expected[0:16383],generic_expected[0:16383];
    reg [15:0] sine_expected[0:1023];
    wavetable_synth #(.COMPACT_ROM(1)) packed_engine(
        .clk(clk),.rst_n(rst_n),.fs_tick(1'b0),.test_mode(1'b0),.gate(32'd0),.retrigger(32'd0),
        .note_bus(224'd0),.vel_bus(256'd0),.timbre_bus(128'd0),.pitch(9'sd0));
    wavetable_synth_v015_reference reference_engine(
        .clk(clk),.rst_n(rst_n),.fs_tick(1'b0),.test_mode(1'b0),.gate(32'd0),.retrigger(32'd0),
        .note_bus(224'd0),.vel_bus(256'd0),.timbre_bus(128'd0),.pitch(9'sd0));
    // Omit COMPACT_ROM entirely: compatibility must be the default.
    wavetable_synth #(.FILE("stress_wave.hex"),.PACKED_FILE("intentionally_absent.hex")) generic_engine(
        .clk(clk),.rst_n(rst_n),.fs_tick(1'b0),.test_mode(1'b0),.gate(32'd0),.retrigger(32'd0),
        .note_bus(224'd0),.vel_bus(256'd0),.timbre_bus(128'd0),.pitch(9'sd0));
    wavetable_synth_v015_reference #(.FILE("stress_wave.hex")) generic_reference(
        .clk(clk),.rst_n(rst_n),.fs_tick(1'b0),.test_mode(1'b0),.gate(32'd0),.retrigger(32'd0),
        .note_bus(224'd0),.vel_bus(256'd0),.timbre_bus(128'd0),.pitch(9'sd0));
    integer i,address;
    reg [15:0] held_packed,held_full,held_generic,held_generic_ref,held_sine;
    initial begin
        $readmemh("src/timbre_soft.hex",expected);
        $readmemh("stress_wave.hex",generic_expected);
        $readmemh("src/test_sine.hex",sine_expected);
        repeat(3) @(negedge clk);rst_n=1;
        for(i=0;i<16384;i=i+1) begin
            // 8191 is coprime to 16384. The permutation repeatedly changes
            // timbre and sign while visiting every address exactly once.
            address=(i*8191)%16384;
            held_packed=packed_engine.rom_q;held_full=reference_engine.rom_q;
            held_generic=generic_engine.rom_q;held_generic_ref=generic_reference.rom_q;
            held_sine=packed_engine.sine_q;
            packed_engine.rom_address=address;reference_engine.rom_address=address;
            generic_engine.rom_address=address;generic_reference.rom_address=address;
            #1;
            if(packed_engine.rom_q!==held_packed || reference_engine.rom_q!==held_full ||
                generic_engine.rom_q!==held_generic || generic_reference.rom_q!==held_generic_ref ||
                packed_engine.sine_q!==held_sine)
                $fatal(1,"PACKED_ROM_LOOKUP latency changed before clock address=%0d",address);
            @(posedge clk);#1;
            if(packed_engine.rom_q!==expected[address] || reference_engine.rom_q!==expected[address] ||
                generic_engine.rom_q!==generic_expected[address] ||
                generic_reference.rom_q!==generic_expected[address] ||
                packed_engine.sine_q!==sine_expected[address%1024] ||
                packed_engine.sine_q!==reference_engine.sine_q)
                $fatal(1,"PACKED_ROM_LOOKUP data/latency address=%0d packed=%h ref=%h expected=%h",
                    address,packed_engine.rom_q,reference_engine.rom_q,expected[address]);
            @(negedge clk);
        end
        $display("PACKED_ROM_LOOKUP_TEST_PASS addresses=16384 packed_and_default_generic latency=1 sine_unchanged");
        $finish;
    end
    initial begin #1000000;$fatal(1,"PACKED_ROM_LOOKUP_TEST_FAIL watchdog");end
endmodule

// Production instance uses COMPACT_ROM=1; compare the complete audio path,
// including PT8211 serial outputs, against the frozen V015 production layer.
module tb_packed_rom_audio;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,note_on=0,note_off=0,hit0=0,hit1=0;
    reg [6:0] note=69;
    reg [7:0] velocity=192,volume=160;
    reg [3:0] timbre=0;
    reg signed [8:0] pitch=0;
    reg zero_test=0,filter_enable=1,owned=0,test_mode=0,clear_audio=0,ready=1;
    reg [31:0] test_mask=0;
    reg [8:0] gain=256;
    wire bck0,ws0,din0,over0,tick0,bck1,ws1,din1,over1,tick1;
    wire [15:0] pcm0,pcm1;
    wire signed [8:0] pitch0,pitch1;
    wire [31:0] busy0,busy1,audible0,audible1;
    instrument_audio #(.TRANSITION_INPUT_ENABLE(1)) candidate(
        .clk(clk),.rst_n(rst_n),.note_on(note_on),.note_off(note_off),.note(note),.velocity(velocity),
        .timbre(timbre),.slider_volume(volume),.slider_pitch(pitch),.hit0(hit0),.hit1(hit1),
        .velocity0(8'd190),.velocity1(8'd170),.digital_zero_test(zero_test),.filter_enable(filter_enable),
        .test_owned(owned),.test_mode(test_mode),.test_clear(clear_audio),.normal_input_ready(ready),
        .test_gate_mask(test_mask),.test_master_gain(gain),.hp_bck(bck0),.hp_ws(ws0),.hp_din(din0),
        .overrun(over0),.monitor_tick(tick0),.monitor_pcm(pcm0),.monitor_pitch(pitch0),
        .monitor_busy(busy0),.monitor_test_busy(audible0));
    instrument_audio_v015_reference #(.TRANSITION_INPUT_ENABLE(1)) baseline(
        .clk(clk),.rst_n(rst_n),.note_on(note_on),.note_off(note_off),.note(note),.velocity(velocity),
        .timbre(timbre),.slider_volume(volume),.slider_pitch(pitch),.hit0(hit0),.hit1(hit1),
        .velocity0(8'd190),.velocity1(8'd170),.digital_zero_test(zero_test),.filter_enable(filter_enable),
        .test_owned(owned),.test_mode(test_mode),.test_clear(clear_audio),.normal_input_ready(ready),
        .test_gate_mask(test_mask),.test_master_gain(gain),.hp_bck(bck1),.hp_ws(ws1),.hp_din(din1),
        .overrun(over1),.monitor_tick(tick1),.monitor_pcm(pcm1),.monitor_pitch(pitch1),
        .monitor_busy(busy1),.monitor_test_busy(audible1));
    integer clocks=0,frames=0,normal_nonzero=0,test_nonzero=0;
    integer f,c,v,partial_checks=0;
    reg [15:0] tones_seen=0;
    always @(posedge clk) begin
        #1;
        if({bck0,ws0,din0,over0,tick0,pcm0,pitch0,busy0,audible0} !==
           {bck1,ws1,din1,over1,tick1,pcm1,pitch1,busy1,audible1})
            $fatal(1,"PACKED_ROM_AUDIO mismatch clock=%0d PCM=%h/%h",clocks,pcm0,pcm1);
        if(rst_n && ((^pcm0)===1'bx || over0!==0))
            $fatal(1,"PACKED_ROM_AUDIO unknown PCM or overrun clock=%0d",clocks);
        clocks=clocks+1;
        if(rst_n && tick0) begin
            frames=frames+1;
            if(pcm0!=0) begin
                if(test_mode) test_nonzero=test_nonzero+1;
                else normal_nonzero=normal_nonzero+1;
            end
            if(test_mode && test_mask!=0 && test_mask!=32'hffffffff) partial_checks=partial_checks+1;
        end
    end
    task run_frame;
        begin
            @(negedge clk);while(!tick0) @(negedge clk);
            @(negedge clk);
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst_n=1;
        if(candidate.synth.COMPACT_ROM!==1 || baseline.synth.NUM_VOICES!=32)
            $fatal(1,"PACKED_ROM_AUDIO production enable/voice count");
        for(f=0;f<800;f=f+1) begin
            if(f<64) begin
                note=48+(f%32);timbre=f%16;velocity=(f%2)?255:192;
                note_on=1;tones_seen[timbre]=1;
            end
            hit0=(f==100);hit1=(f==120);pitch=(f<400)?9'sd255:-9'sd256;
            run_frame;note_on=0;hit0=0;hit1=0;
        end
        owned=1;ready=0;test_mode=1;test_mask=32'hffffffff;clear_audio=1;
        repeat(2) @(negedge clk);clear_audio=0;
        for(f=0;f<700;f=f+1) begin
            if(f==400) test_mask=32'hfffdffff;
            if(f==500) test_mask=32'hffffffff;
            if(f>=600) gain=(f%3==0)?0:((f%3==1)?128:256);
            run_frame;
        end
        test_mode=0;test_mask=0;gain=256;clear_audio=1;
        repeat(2) @(negedge clk);clear_audio=0;owned=0;ready=1;note=69;timbre=15;note_on=1;
        run_frame;note_on=0;
        repeat(400) run_frame;
        if(tones_seen!==16'hffff || normal_nonzero<100 || test_nonzero<100 || partial_checks<50)
            $fatal(1,"PACKED_ROM_AUDIO coverage normal=%0d test=%0d partial=%0d",normal_nonzero,test_nonzero,partial_checks);
        $display("PACKED_ROM_AUDIO_TEST_PASS clocks=%0d frames=%0d normal_nonzero=%0d test_nonzero=%0d all_16_timbres serial_bits_equal",
            clocks,frames,normal_nonzero,test_nonzero);
        $finish;
    end
    initial begin #10000000;$fatal(1,"PACKED_ROM_AUDIO_TEST_FAIL watchdog");end
endmodule
