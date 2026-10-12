`timescale 1ns/1ps
module mock_ads1115(input rst,input [63:0] analog_values,inout scl,inout sda);
  reg slave_low=0;
  assign sda=slave_low?1'b0:1'bz;
  reg receiving=1,active=0;
  integer bitcount=0,bytes=0,txstage=0;
  reg [7:0] rx=0,ptr=0,config_high=0;
  reg [1:0] selected=0;
  reg [15:0] mock;
  always @(*) case(selected)
    0:mock=analog_values[15:0];1:mock=analog_values[31:16];2:mock=analog_values[47:32];default:mock=analog_values[63:48];
  endcase
  reg [7:0] txbyte;
  always @(negedge sda) if(scl===1'b1) begin
    active=1;receiving=1;bitcount=0;bytes=0;rx=0;slave_low=0;
  end
  always @(posedge sda) if(scl===1'b1) begin active=0;slave_low=0;bitcount=0;bytes=0;receiving=1;end
  always @(posedge scl) if(rst && active) begin
    if(receiving) begin
      if(bitcount<8) begin
        rx={rx[6:0],sda};bitcount=bitcount+1;
        if(bitcount==8) begin
          if(bytes==0 && rx!==8'h90 && rx!==8'h91) $fatal(1,"wrong I2C address %h",rx);
          if(bytes==1) ptr=rx;
          if(bytes==2 && ptr==1) config_high=rx;
          if(bytes==3 && ptr==1) begin
            if(config_high[7:6]!==2'b11 || config_high[3:0]!==4'h3 || rx!==8'he3)
              $fatal(1,"incorrect ADS config %h%h",config_high,rx);
            selected=config_high[5:4];
          end
        end
      end else begin
        bitcount=0;
        if(bytes==0 && rx==8'h91) begin receiving=0;txstage=0;txbyte=mock[15:8];end
        bytes=bytes+1;rx=0;
      end
    end else begin
      if(bitcount<8) bitcount=bitcount+1;
      else begin
        if(txstage==0) begin
          if(sda!==0) $fatal(1,"master did not ACK first byte");
          txstage=1;txbyte=mock[7:0];bitcount=0;
        end else begin
          if(sda!==1) $fatal(1,"master did not NACK final byte");
          receiving=1;bitcount=0;
        end
      end
    end
  end
  always @(negedge scl) begin
    if(!active) slave_low=0;
    else if(receiving) slave_low=(bitcount==8);
    else slave_low=(bitcount<8)?!txbyte[7-bitcount]:0;
  end
endmodule
