// TMDS输出：pixel_clk25.2MHz，serial_clk126MHz，OSER10双沿串行=252Mbit/s。
// 每通道8bit颜色编码成10bit，数据通道0蓝/1绿/2红，位0最先发送。
// 输入RGB与de/hsync/vsync必须已经同拍对齐；蓝通道消隐携带同步控制码。
// rst_n由pixel域同步释放；serial域另用三拍同步后释放OSER10复位。
// TLVDS_OBUF输出真实差分对，不能用单端反相替代；引脚见CST差分对。
// 时钟通道也经过OSER10同类流水线，五高五低对齐数据，勿单独直连pixel_clk。
// 没有音频、数据岛或HDCP；这是DVI兼容的视频链路。

module hdmi_tx(input pixel_clk,input serial_clk,input rst_n,
    input [7:0] red,green,blue,input de,input hsync,input vsync,
    output tmds_clk_p,tmds_clk_n,output [2:0] tmds_data_p,tmds_data_n);
    wire [9:0] word0,word1,word2;
    wire [2:0] serial_data;
    // Do not release IOLOGIC reset directly on a pixel-clock edge.
    (* syn_preserve=1 *) reg [2:0] serializer_reset_sync;
    always @(posedge serial_clk or negedge rst_n)
        if(!rst_n)serializer_reset_sync<=0;
        else serializer_reset_sync<={serializer_reset_sync[1:0],1'b1};
    wire serializer_reset=!serializer_reset_sync[2];
    tmds_encoder u_blue(pixel_clk,rst_n,blue,de,hsync,vsync,word0);
    tmds_encoder u_green(pixel_clk,rst_n,green,de,1'b0,1'b0,word1);
    tmds_encoder u_red(pixel_clk,rst_n,red,de,1'b0,1'b0,word2);
    genvar ch;
    generate for(ch=0;ch<3;ch=ch+1) begin:channels
        wire [9:0] word_ch;
        assign word_ch=(ch==0)?word0:((ch==1)?word1:word2);
        OSER10 u_serializer(.Q(serial_data[ch]),
            .D0(word_ch[0]),.D1(word_ch[1]),.D2(word_ch[2]),
            .D3(word_ch[3]),.D4(word_ch[4]),.D5(word_ch[5]),
            .D6(word_ch[6]),.D7(word_ch[7]),.D8(word_ch[8]),.D9(word_ch[9]),
            .PCLK(pixel_clk),.FCLK(serial_clk),.RESET(serializer_reset));
        TLVDS_OBUF u_out(.I(serial_data[ch]),.O(tmds_data_p[ch]),.OB(tmds_data_n[ch]));
    end endgenerate
    // Clock lane has the same serializer pipeline as the three data lanes.
    // 0000011111 LSB first gives five high followed by five low bit periods.
    wire clock_serial;
    OSER10 u_clock_serializer(.Q(clock_serial),
        .D0(1'b1),.D1(1'b1),.D2(1'b1),.D3(1'b1),.D4(1'b1),
        .D5(1'b0),.D6(1'b0),.D7(1'b0),.D8(1'b0),.D9(1'b0),
        .PCLK(pixel_clk),.FCLK(serial_clk),.RESET(serializer_reset));
    TLVDS_OBUF u_clock_out(.I(clock_serial),.O(tmds_clk_p),.OB(tmds_clk_n));
endmodule
