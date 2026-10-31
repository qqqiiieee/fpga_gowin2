`timescale 1ns/1ps
module tb_builtin_rom;
    reg clk=0; always #5 clk=~clk;
    reg [9:0] addr=0;
    wire [31:0] data;
    wire [5:0] steps,beats;
    wire [17:0] samples;
    reg [31:0] previous;
    integer a;
    piano_builtin_score_ram dut(.read_clk(clk),.read_addr(addr),.read_data(data),
        .total_steps(steps),.total_beats(beats),.beat_samples(samples));
    `include "src/piano_song_rom_v045.vh"
    // This verifies the packed BRAM image against the independently generated
    // event/slot/next functions, including every padded/reserved address.
    initial begin
        @(posedge clk);#1;
        for(a=0;a<1024;a=a+1)begin
            @(negedge clk);previous=data;addr=a;#1;
            if(data!==previous)$fatal(1,"ROM read must be synchronous addr=%0d",a);
            if(steps!==song_v045_count(addr[9:8]) || beats!==song_v045_total_beats(addr[9:8]) ||
               samples!==song_v045_beat_samples(addr[9:8]))$fatal(1,"metadata addr=%0d",a);
            @(posedge clk);#1;
            if(data!==song_v045_word(addr[9:8],addr[7:0]))
                $fatal(1,"ROM word addr=%0d got=%h ref=%h",a,data,song_v045_word(addr[9:8],addr[7:0]));
        end
        $display("BUILTIN_ROM_PASS addresses=1024 metadata=1024 synchronous=1 reserved_zero=1");
        $finish;
    end
endmodule
