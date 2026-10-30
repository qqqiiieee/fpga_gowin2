`timescale 1ns/1ps
// Settle the unchanged bench's declaration-initialized combinational key input
// during reset, before its first 5 ns clock. See iverilog_tmds_startup.v.
module iverilog_telemetry_startup;
    initial begin
        #1; force tb_instrument_telemetry.keys = 12'h001;
        #1; force tb_instrument_telemetry.keys = 12'h000;
        #0; release tb_instrument_telemetry.keys;
    end
endmodule
