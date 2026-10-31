`timescale 1ns/1ps
// Optional guide sidecar; all ports are synchronous to the guide's clk.
// 0=fixed BPM (no hold/audio), 1=demo, 2=step practice, 3=safe fixed fallback.
// restart covers start/restart, song replacement and custom-score commit.
// running = guide.active && !guide.done. suspended is EXTERNAL ownership pause;
// do NOT include practice_hold in suspended, or practice can never accept a key.
// score_ready distinguishes a RAM read bubble from a real rest. Tie high for
// built-in scores. Keep step_index constant throughout one note, and give every
// new note (including adjacent repetitions / after a rest) a different step.
// No score_onset input is needed: existing onset is a whole beat/quarter LEVEL.
// midi_note_on is a fresh, one-clock, nonzero-velocity MELODY NoteOn at receipt,
// not held_notes, an audio-arbiter pending event, or an unconsumed FIFO valid.
// No incoming event is queued. Boundary/paused/unready pulses are discarded.
// A low pulse sample must precede acceptance; a pulse spanning a boundary cannot
// unlock its successor. Arbitrarily delayed upstream events need an upstream
// receipt/epoch tag; pulse+pitch alone cannot tell their age.
// Demo gates are MIDI pitches 41..72, NOT voice allocator slot numbers. Route
// demo_retrigger to a consumer that captures every clk (not just sample_tick).
// Gates dropping releases notes; hard-muting ADSR/FX tails is the audio owner's
// responsibility. Invalid score pitches are silent in demo, never transposed.
module guide_play_modes #(
    parameter [7:0] DEMO_VELOCITY = 8'd192
)(
    input wire clk,
    input wire rst_n,
    input wire [1:0] mode,
    input wire running,
    input wire suspended,
    input wire restart,
    input wire score_ready,
    input wire [6:0] expected_note,
    input wire expected_valid,
    input wire [5:0] step_index,
    input wire midi_note_on,
    input wire [6:0] midi_note,
    output wire practice_hold,
    output wire [31:0] demo_gate,
    output wire [31:0] demo_retrigger,
    output wire [7:0] demo_velocity,
    // Compact event adapter interface; unconnected 32-bit gates synthesize away.
    output wire demo_valid,
    output wire [6:0] demo_note,
    output wire demo_note_retrigger
);
    // 20 explicit state bits; no counter, bitmap history, UART, RAM or FIFO.
    reg [1:0] mode_q;
    reg [5:0] target_step;
    reg [6:0] target_note;
    reg target_known, accepted, event_armed, demo_active, demo_trigger;

    wire changed = !target_known || step_index != target_step ||
                   expected_note != target_note;
    wire clear_context = restart || mode != mode_q || !running;
    wire in_demo_range = expected_note >= 7'd41 && expected_note <= 7'd72;

    // Combinational comparison stops the guide at the FIRST sample of the new
    // note; a registered hold would leak a sample when sample_tick is adjacent.
    // Real rests/count-in run freely. RAM bubbles freeze only practice and do
    // not erase acceptance, so a multi-quarter long note asks for one key only.
    assign practice_hold = rst_n && mode == 2'd2 && running &&
        (!score_ready || (expected_valid &&
         (clear_context || changed || !accepted)));

    wire demo_enable = rst_n && mode == 2'd1 && running && !suspended &&
        !clear_context && demo_active &&
        (!score_ready || (expected_valid && !changed));
    genvar pitch;
    generate for (pitch=0; pitch<32; pitch=pitch+1) begin: demo_pitches
        assign demo_gate[pitch] = demo_enable && target_note == (pitch+41);
        assign demo_retrigger[pitch] = demo_gate[pitch] && demo_trigger;
    end endgenerate
    assign demo_velocity = DEMO_VELOCITY;
    assign demo_valid = demo_enable;
    assign demo_note = target_note;
    assign demo_note_retrigger = demo_enable && demo_trigger;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mode_q <= 2'd0;
            target_step <= 0;
            target_note <= 0;
            target_known <= 0;
            accepted <= 0;
            event_armed <= 0;
            demo_active <= 0;
            demo_trigger <= 0;
        end else begin
            mode_q <= mode;
            demo_trigger <= 0;
            if (clear_context) begin
                target_known <= 0;
                accepted <= 0;
                event_armed <= 0;
                demo_active <= 0;
            end else if (suspended) begin
                // Ownership pause preserves an already accepted note's timing,
                // but never remembers a paused key or leaves a demo gate on.
                event_armed <= 0;
                demo_active <= 0;
            end else if (!score_ready) begin
                // Preserve note identity/gate/acceptance across sync-RAM reads.
                event_armed <= 0;
            end else if (!expected_valid) begin
                event_armed <= 0;
                demo_active <= 0;
            end else begin
                if (changed) begin
                    target_step <= step_index;
                    target_note <= expected_note;
                    target_known <= 1;
                    accepted <= 0;
                    event_armed <= !midi_note_on;
                end else if (mode == 2'd2) begin
                    if (!midi_note_on) event_armed <= 1;
                    else begin
                        event_armed <= 0;
                        if (event_armed && !accepted && midi_note == expected_note)
                            accepted <= 1;
                    end
                end else event_armed <= 0;

                if (mode == 2'd1 && in_demo_range) begin
                    demo_active <= 1;
                    // A new step retriggers even when the pitch never changes.
                    // Resuming a paused demo starts the remaining note afresh.
                    if (changed || !demo_active) demo_trigger <= 1;
                end else demo_active <= 0;
            end
        end
    end
endmodule
