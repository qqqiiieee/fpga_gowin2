// V045 immutable 1024x32 synchronous score ROM: {song[1:0], quarter[7:0]}.
// One quarter is 16 roll ticks (1/4 BEAT). Instantiate once per clock domain;
// the source and pixel copies have independent read clocks, with no CDC bus.
// 32-bit payload is exactly song_v045_word/custom_score_ram format:
// [31:24] velocity, [23] next_valid, [22:16] next_note, [15] long-note hint,
// [14] onset QUARTER, [13] pitched valid, [12:7] step, [6:0] MIDI note.
// Rests retain their step; count-in previews the first note; end is silent.
// Bank 3 is entirely zero and reserved for the separate custom-score store.
// No reset on memory/read_data: retain the synchronous block-ROM template.
// Consumers MUST match a registered address tag before using read_data.
module piano_builtin_score_ram (
    input read_clk, input [9:0] read_addr,
    output reg [31:0] read_data,
    // Tiny combinational metadata depends on the REQUEST song (not read tag).
    // Only these metadata helpers are called; event/slot/word functions from
    // the reference include are never evaluated in the synthesized datapath.
    output [5:0] total_steps, output [5:0] total_beats,
    output [17:0] beat_samples
);
    `include "src/piano_song_rom_v045.vh"
    reg [31:0] memory [0:1023] /* synthesis syn_romstyle = "block_rom" */;
    // Run tools from the project root (or a snapshot with src/ preserved).
    initial $readmemh("src/piano_builtin_score.hex", memory);
    always @(posedge read_clk) read_data <= memory[read_addr];
    assign total_steps = song_v045_count(read_addr[9:8]);
    assign total_beats = song_v045_total_beats(read_addr[9:8]);
    assign beat_samples = song_v045_beat_samples(read_addr[9:8]);
endmodule
