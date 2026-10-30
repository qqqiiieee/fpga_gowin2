`timescale 1ns/1ps
// 独立V015快照与定宽后的模块逐拍比较，覆盖命令、总线延展/拉低、恢复和重复复位。
module i2c_counter_pair #(parameter Q=2,parameter T=127)(input clk,input rst_n,input [31:0] cycle);
    tri1 scl_new,sda_new,scl_old,sda_old;
    wire busy_new,done_new,error_new,busy_old,done_old,error_old;
    wire [7:0] rx_new,rx_old;
    wire stretch=(cycle%251>=109 && cycle%251<126);
    wire pull_data=(cycle%64>=23 && cycle%64<31);
    assign scl_new=stretch?1'b0:1'bz;
    assign scl_old=stretch?1'b0:1'bz;
    assign sda_new=pull_data?1'b0:1'bz;
    assign sda_old=pull_data?1'b0:1'bz;
    wire valid=(cycle%13==0);
    wire [1:0] command=(cycle/13)%4;
    wire [7:0] data=cycle*37;
    i2c_byte_master #(.QUARTER_CYCLES(Q),.TIMEOUT_CYCLES(T)) dut(
        .clk(clk),.rst_n(rst_n),.cmd_valid(valid),.cmd(command),.tx_data(data),.read_nack(cycle[5]),
        .busy(busy_new),.done(done_new),.error(error_new),.rx_data(rx_new),.scl(scl_new),.sda(sda_new));
    v015_i2c_byte_master #(.QUARTER_CYCLES(Q),.TIMEOUT_CYCLES(T)) reference(
        .clk(clk),.rst_n(rst_n),.cmd_valid(valid),.cmd(command),.tx_data(data),.read_nack(cycle[5]),
        .busy(busy_old),.done(done_old),.error(error_old),.rx_data(rx_old),.scl(scl_old),.sda(sda_old));
    always @(posedge clk)begin
        #1;
        if(rst_n && {busy_new,done_new,error_new,rx_new,scl_new,sda_new}!==
                    {busy_old,done_old,error_old,rx_old,scl_old,sda_old})
            $fatal(1,"I2C byte mismatch Q=%0d T=%0d cycle=%0d",Q,T,cycle);
    end
endmodule
module recovery_counter_pair #(parameter Q=2,parameter T=127)(input clk,input rst_n,input [31:0] cycle);
    tri1 scl_new,sda_new,scl_old,sda_old;
    wire busy_new,done_new,error_new,busy_old,done_old,error_old;
    wire stretch=(cycle%911>=300 && cycle%911<333);
    wire pull_data=(cycle%991>=700 && cycle%991<800);
    assign scl_new=stretch?1'b0:1'bz;assign scl_old=stretch?1'b0:1'bz;
    assign sda_new=pull_data?1'b0:1'bz;assign sda_old=pull_data?1'b0:1'bz;
    wire start=(cycle%137==0);
    i2c_bus_recovery #(.QUARTER_CYCLES(Q),.TIMEOUT_CYCLES(T)) dut(
        .clk(clk),.rst_n(rst_n),.start(start),.busy(busy_new),.done(done_new),.error(error_new),.scl(scl_new),.sda(sda_new));
    v015_i2c_bus_recovery #(.QUARTER_CYCLES(Q),.TIMEOUT_CYCLES(T)) reference(
        .clk(clk),.rst_n(rst_n),.start(start),.busy(busy_old),.done(done_old),.error(error_old),.scl(scl_old),.sda(sda_old));
    always @(posedge clk)begin
        #1;
        if(rst_n && {busy_new,done_new,error_new,scl_new,sda_new}!=={busy_old,done_old,error_old,scl_old,sda_old})
            $fatal(1,"I2C recovery mismatch Q=%0d T=%0d cycle=%0d",Q,T,cycle);
    end
endmodule
module reader_counter_pair #(parameter Q=2,parameter T=127,parameter WAIT=9,parameter RETRY=17)(input clk,input rst_n,input [31:0] cycle);
    tri1 scl_new,sda_new,scl_old,sda_old;
    wire valid_new,fault_new,valid_old,fault_old;
    wire [1:0] channel_new,channel_old;
    wire [15:0] data_new,data_old;
    wire stretch=(cycle%997>=300 && cycle%997<350);
    wire pull_data=(cycle%317>=100 && cycle%317<110);
    assign scl_new=stretch?1'b0:1'bz;assign scl_old=stretch?1'b0:1'bz;
    assign sda_new=pull_data?1'b0:1'bz;assign sda_old=pull_data?1'b0:1'bz;
    ads1115_reader #(.I2C_QUARTER(Q),.BYTE_TIMEOUT_CYCLES(T),.CONVERT_CYCLES(WAIT),.RETRY_CYCLES(RETRY)) dut(
        .clk(clk),.rst_n(rst_n),.scl(scl_new),.sda(sda_new),.sample_valid(valid_new),.sample_channel(channel_new),.sample_data(data_new),.fault(fault_new));
    v015_ads1115_reader #(.I2C_QUARTER(Q),.BYTE_TIMEOUT_CYCLES(T),.CONVERT_CYCLES(WAIT),.RETRY_CYCLES(RETRY)) reference(
        .clk(clk),.rst_n(rst_n),.scl(scl_old),.sda(sda_old),.sample_valid(valid_old),.sample_channel(channel_old),.sample_data(data_old),.fault(fault_old));
    always @(posedge clk)begin
        #1;
        if(rst_n && {valid_new,fault_new,channel_new,data_new,scl_new,sda_new}!=={valid_old,fault_old,channel_old,data_old,scl_old,sda_old})
            $fatal(1,"ADC reader mismatch Q=%0d T=%0d cycle=%0d",Q,T,cycle);
    end
endmodule
module tb_counter_resource_equivalence;
    reg clk=0,rst_n=0;always #5 clk=~clk;
    reg [31:0] cycle=0;
    i2c_counter_pair a(clk,rst_n,cycle);
    i2c_counter_pair #(.Q(1),.T(1)) a_min(clk,rst_n,cycle);
    recovery_counter_pair b(clk,rst_n,cycle);
    recovery_counter_pair #(.Q(1),.T(1)) b_min(clk,rst_n,cycle);
    reader_counter_pair c(clk,rst_n,cycle);
    reader_counter_pair #(.Q(1),.T(1),.WAIT(1),.RETRY(1)) c_min(clk,rst_n,cycle);
    integer i;
    initial begin
        repeat(5)@(negedge clk);rst_n=1;
        for(i=0;i<20000;i=i+1)begin
            @(negedge clk);cycle=i;
            if(i==7000 || i==14000)rst_n=0;
            if(i==7005 || i==14005)rst_n=1;
        end
        @(negedge clk);
        $display("COUNTER_RESOURCE_EQUIVALENCE_TEST_PASS cycles=20000 module_pairs=6 repeated_resets=2");
        $finish;
    end
endmodule
