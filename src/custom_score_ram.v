// One logical 512x32 simple-dual-port block RAM, two banks of 256 quarters.
// Instantiate ONCE in guide and ONCE in renderer, broadcasting the same write
// bus to both. There is no reset/clear loop or asynchronous read mux: those
// would turn a nearly-full device's score store into distributed LUT RAM.
// read_data is from read_addr sampled at the previous read clock edge.
// Read/write of the SAME bank is outside the protocol: the controller writes
// inactive bank and may reuse the old bank only after the pixel bank ACK.
// Uninitialised words are intentional; config.valid is published only after
// all 256 words (including count-in and silent padding) have been written.
module custom_score_ram (
    input custom_write_clk, input custom_write_en,
    input [8:0] custom_write_addr, input [31:0] custom_write_data,
    input read_clk, input [8:0] read_addr,
    output reg [31:0] read_data
);
    reg [31:0] memory [0:511] /* synthesis syn_ramstyle = "block_ram" */;
    always @(posedge custom_write_clk)
        if (custom_write_en) memory[custom_write_addr] <= custom_write_data;
    always @(posedge read_clk)
        read_data <= memory[read_addr];
endmodule
