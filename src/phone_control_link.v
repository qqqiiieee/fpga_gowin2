`timescale 1ns/1ps
// 手机控制协议 v1，独立3.3V UART，不接管USB虚拟输入，也不传输音频。
// 每帧12字节，只有完整头/版本/保留位/XOR/范围全部正确才提交SET或Panic。
// 参数是绝对值，因此桥接端重试不会把切换命令执行两遍；同一时刻仅一笔请求。
// ACK在提交后等待6个clk，采集后级真实回读；绝不直接把请求值当作生效值。
// 正在发ACK时忽略新请求，发送端必须等ACK。坏校验无ACK，半帧20ms自动丢弃。
module phone_control_link #(
    parameter integer CLK_HZ=27000000,
    parameter integer BAUD=115200,
    parameter integer TIMEOUT_CYCLES=540000,
    parameter integer TELEMETRY_ENABLE=0 // V038：新增只读16..31，0保留原协议范围。
)(
    input wire clk,rst_n,rx,
    output wire tx,
    output reg set_valid,panic,
    output reg [7:0] param,value,
    input wire [7:0] read_value,status_flags,current_timbre,current_fx,current_volume,
    output reg get_valid // 合法GET提交；同序号紧邻重试GET16不再次锁存快照。
);
    localparam integer BC=(CLK_HZ+BAUD/2)/BAUD;
    localparam integer BW=BC<2?1:$clog2(BC);
    localparam integer TC=TIMEOUT_CYCLES<1?1:TIMEOUT_CYCLES;
    localparam integer TW=TC<2?1:$clog2(TC);
    localparam [1:0] RECEIVE=0,SETTLE=1,TRANSMIT=2;
    wire [7:0] rx_data;
    wire rx_valid,rx_error;
    midi_uart_rx #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) receiver(
        .clk(clk),.rst_n(rst_n),.rx(rx),.data(rx_data),
        .data_valid(rx_valid),.framing_error(rx_error));
    reg [1:0] state;
    reg [3:0] pos;
    reg [TW-1:0] age;
    reg [7:0] version,seq,command,checksum,result;
    reg reserved_bad;
    // GET16具有锁存快照的副作用。同一笔请求因丢ACK重发时必须复用原
    // 快照，保证重试返回的低字节与后续高字节仍属于同一次采样。
    reg [7:0] previous_request_seq;
    reg previous_was_snapshot;
    reg [2:0] settle;
    reg [95:0] packet;
    reg [9:0] serial_word;
    reg [BW-1:0] bit_timer;
    reg [3:0] bit_index,byte_index;
    assign tx=state==TRANSMIT ? serial_word[0] : 1'b1;

    // 控制码范围在协议边界约束，避免错误网页/串口数据写坏后级状态。
    function [7:0] command_result;
        input [7:0] ver,cmd,idx,val;
        input bad_reserved;
        begin
            command_result=0;
            if(ver!=1 || bad_reserved)command_result=4;
            else if(cmd>2)command_result=1;
            else if(cmd==2)begin
                if(idx!=0 || val!=0)command_result=3;
            end else if(idx>(TELEMETRY_ENABLE ? 31 : 15) ||
                        (cmd==1 && idx>=15))command_result=2;
            else if(cmd==0 && val!=0)command_result=3;
            else if(cmd==1)begin
                case(idx)
                    1,13,14: if(val>1)command_result=3;
                    2: if(val>2)command_result=3; // KEY / STRUM / HYBRID
                    3,12: if(val>3)command_result=3;
                    default: ;
                endcase
            end
        end
    endfunction
    wire [7:0] checked_result=command_result(version,command,param,value,reserved_bad);
    wire [7:0] reply_xor=8'h01 ^ seq ^ result ^ param ^ read_value ^
        status_flags ^ current_timbre ^ current_fx ^ current_volume;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            state<=RECEIVE;pos<=0;age<=0;version<=0;seq<=0;command<=0;
            checksum<=0;result<=0;reserved_bad<=0;param<=0;value<=0;
            set_valid<=0;panic<=0;get_valid<=0;settle<=0;packet<=0;serial_word<=10'h3ff;
            bit_timer<=0;bit_index<=0;byte_index<=0;
            previous_request_seq<=0;previous_was_snapshot<=0;
        end else begin
            set_valid<=0;panic<=0;get_valid<=0;
            case(state)
                RECEIVE:begin
                    if(pos==0)age<=0;
                    else if(age==TC-1)begin pos<=0;age<=0;end
                    else age<=age+1'b1;
                    if(rx_error)begin pos<=0;age<=0;end
                    else if(rx_valid)begin
                        age<=0;
                        case(pos)
                            0:if(rx_data==8'ha5)pos<=1;
                            1:begin
                                if(rx_data==8'h5a)begin pos<=2;checksum<=0;reserved_bad<=0;end
                                else if(rx_data!=8'ha5)pos<=0;
                            end
                            2:begin version<=rx_data;checksum<=rx_data;pos<=3;end
                            3:begin seq<=rx_data;checksum<=checksum^rx_data;pos<=4;end
                            4:begin command<=rx_data;checksum<=checksum^rx_data;pos<=5;end
                            5:begin param<=rx_data;checksum<=checksum^rx_data;pos<=6;end
                            6:begin value<=rx_data;checksum<=checksum^rx_data;pos<=7;end
                            7,8,9,10:begin
                                reserved_bad<=reserved_bad || rx_data!=0;
                                checksum<=checksum^rx_data;pos<=pos+1'b1;
                            end
                            11:begin
                                pos<=0;
                                if(rx_data==checksum)begin
                                    result<=checked_result;
                                    set_valid<=checked_result==0 && command==1;
                                    panic<=checked_result==0 && command==2;
                                    get_valid<=checked_result==0 && command==0 &&
                                        !(TELEMETRY_ENABLE && param==16 &&
                                          previous_was_snapshot && seq==previous_request_seq);
                                    if(checked_result==0)begin
                                        previous_request_seq<=seq;
                                        previous_was_snapshot<=command==0 && param==16;
                                    end
                                    settle<=0;state<=SETTLE;
                                end
                            end
                            default:pos<=0;
                        endcase
                    end
                end
                SETTLE:begin
                    if(settle==6)begin
                        packet<={reply_xor,current_volume,current_fx,current_timbre,
                            status_flags,read_value,param,result,seq,8'h01,8'ha5,8'h5a};
                        serial_word<={1'b1,8'h5a,1'b0};
                        bit_timer<=BC-1;bit_index<=0;byte_index<=0;state<=TRANSMIT;
                    end else settle<=settle+1'b1;
                end
                TRANSMIT:begin
                    if(bit_timer!=0)bit_timer<=bit_timer-1'b1;
                    else begin
                        bit_timer<=BC-1;
                        if(bit_index==9)begin
                            bit_index<=0;
                            if(byte_index==11)begin state<=RECEIVE;pos<=0;age<=0;end
                            else begin
                                byte_index<=byte_index+1'b1;packet<=packet>>8;
                                serial_word<={1'b1,packet[15:8],1'b0};
                            end
                        end else begin
                            serial_word<={1'b1,serial_word[9:1]};bit_index<=bit_index+1'b1;
                        end
                    end
                end
                default:begin state<=RECEIVE;pos<=0;end
            endcase
        end
    end
endmodule
