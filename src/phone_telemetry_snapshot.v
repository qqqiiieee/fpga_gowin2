// V038只读遥测：与参数控制共用原12字节UART帧，不接管演奏输入。
// GET31返回能力码A7；合法GET16令capture打一拍，一次锁存全部15个数据字节。
// GET17..30只读同一份快照；不能每读一个字节重新取样，否则16位ADC高低字节会撕裂。
// 复位前/首次capture前数据为0，slot22.bit7=0表示未有有效快照。
// 所有输入与寄存器均属于clk域；不会增加音频路径的运算、时钟或复位负载。
module phone_telemetry_snapshot(
    input clk,input rst_n,input capture,input [7:0] index,
    input [31:0] adc_raw,input [7:0] pressure0,pressure1,
    input [1:0] calibrated,input [7:0] flags,
    input [13:0] external_diagnostic,
    input [7:0] midi_velocity,input signed [8:0] midi_bend,
    input [6:0] midi_modulation,input [5:0] voices,test_requested,
    input test_owned,test_mode,test_sweep,input [4:0] test_index,
    output [7:0] value
);
    reg [119:0] snapshot;
    // [7]有效，[6]MIDI溢出，[5]MIDI帧错，[4]光电完成启动学习，
    // [3]ADC过期，[2]ADC故障，[1:0]两路FSR各自校准完成位。
    wire [7:0] sensor_flags={1'b1,external_diagnostic[4],external_diagnostic[1],
        external_diagnostic[5],flags[4],flags[3],calibrated};
    // [7]测试拥有输出，[6]测试音源模式，[5]扫弦播放busy，[4]光电编译使能，
    // [3:2]B/A相对上电基线的遮挡状态，[1:0]B/A滤波后电平。
    wire [7:0] beam_flags={test_owned,test_mode,external_diagnostic[6],
        external_diagnostic[9],external_diagnostic[3:2],external_diagnostic[8:7]};
    // 掩码/索引只说明控制状态，不把请求路数当成瞬时可闻声部数。
    wire [7:0] test_flags={test_index,flags[7],test_sweep,test_owned};
    always @(posedge clk or negedge rst_n)
        if(!rst_n)snapshot<=0;
        else if(capture)snapshot<={test_flags,{2'd0,test_requested},{2'd0,voices},
            {1'b0,midi_modulation},{7'd0,midi_bend[8]},midi_bend[7:0],midi_velocity,
            beam_flags,sensor_flags,pressure1,pressure0,adc_raw};
    // 位选只用低4位，避免把8位PARAM减法扩成32位大移位器。
    assign value=index==8'd31 ? 8'ha7 :
        ((index>=8'd16 && index<=8'd30) ? snapshot[{index[3:0],3'b000}+:8] : 8'd0);
endmodule
