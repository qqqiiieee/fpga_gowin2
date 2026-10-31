`timescale 1ns/1ps
// Independent native function smoke/exhaustive query harness. Python compares
// these values with a sequential walk of source.json; this is not FPGA build RTL.
module song_library_v045_second_scope(
    input [1:0] selected, input [7:0] quarter, output [31:0] word
);
    `include "piano_song_rom_v045.vh"
    assign word = song_v045_word(selected, quarter);
endmodule

module tb_song_library_v045;
    `include "piano_song_rom_v045.vh"
    reg [1:0] selected;
    reg [7:0] quarter;
    reg [7:0] slot;
    wire [31:0] second_word;
    integer s, q, step;
    song_library_v045_second_scope second(selected, quarter, second_word);
    initial begin
        for (s = 0; s < 4; s = s + 1) begin
            selected = s;
            $display("META %0d %0d %0d %0d %0d", s, song_v045_count(selected),
                song_v045_total_beats(selected), song_v045_bpm(selected), song_v045_beat_samples(selected));
            for (step = 0; step < 64; step = step + 1)
                $display("EVENT %0d %0d %h %h", s, step, song_v045_event(selected, step[5:0]),
                    song_v045_next_note(selected, step[5:0]));
            for (q = 0; q < 256; q = q + 1) begin
                quarter = q;
                #1;
                slot = song_v045_slot(selected, quarter);
                if (song_v045_word(selected, quarter) !== second_word) begin
                    $display("FATAL second module include differs song=%0d quarter=%0d", s, q);
                    $finish;
                end
                $display("SLOT %0d %0d %h %h %h", s, q, slot,
                    song_v045_event(selected, slot[5:0]), song_v045_word(selected, quarter));
            end
        end
        $display("SONG_LIBRARY_V045_NATIVE_PASS metadata=4 events=256 quarters=1024");
        $finish;
    end
endmodule
