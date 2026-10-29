`timescale 1ns/1ps
// Icarus does not schedule a Verilog always @* merely because a bench input
// was declaration-initialized before its sensitivity process started. The
// unchanged TMDS bench holds data=0 through its first active video vector.
// Settle that combinational input before the first clock (5 ns), while reset
// remains asserted until 12 ns. No vector, assertion, or DUT state is changed.
module iverilog_tmds_startup;
    initial begin
        #1; force tb_tmds_encoder.data = 8'h01;
        #1; force tb_tmds_encoder.data = 8'h00;
        #0; release tb_tmds_encoder.data;
    end
endmodule
