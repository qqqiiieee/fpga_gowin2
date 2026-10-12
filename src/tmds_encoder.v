// 每像素生成一个10bit TMDS符号，pixel域异步低有效复位。
// data为8bit颜色；de=1有效像素，de=0使用c1/c0控制码并清运行差异。
// 先组合生成低跳变率q，再依据signed disparity选择反相及前缀；输出寄存一拍。
// ones/qones/balance是本像素整数统计，disparity为跨像素的6bit有符号运行差异。
// 保持符号位、q[8]规则及四个固定控制码；OSER10从LSB先发送。
// 只编码视频数据；独立向量回归验证符号及差异更新。

// DVI-compatible video encoding. No HDMI audio/data islands/HDCP.
// Output bits are transmitted LSB first by OSER10.
module tmds_encoder(input pixel_clk,input rst_n,input [7:0] data,
    input de,input c0,input c1,output reg [9:0] symbol);
    reg [8:0] q;
    integer i, ones, qones, balance;
    reg use_xnor;
    reg signed [5:0] disparity;
    always @* begin
        ones=0;
        for(i=0;i<8;i=i+1) ones=ones+data[i];
        use_xnor=(ones>4 || (ones==4 && !data[0]));
        q[0]=data[0];
        for(i=1;i<8;i=i+1) q[i]=use_xnor ? ~(q[i-1]^data[i]) : (q[i-1]^data[i]);
        q[8]=!use_xnor;
        qones=0;
        for(i=0;i<8;i=i+1) qones=qones+q[i];
        balance=2*qones-8;
    end
    always @(posedge pixel_clk or negedge rst_n) begin
        if(!rst_n) begin disparity<=0; symbol<=10'b1101010100; end
        else if(!de) begin
            disparity<=0;
            case({c1,c0})
                2'b00:symbol<=10'b1101010100;
                2'b01:symbol<=10'b0010101011;
                2'b10:symbol<=10'b0101010100;
                2'b11:symbol<=10'b1010101011;
            endcase
        end else if(disparity==0 || balance==0) begin
            symbol<={~q[8],q[8],(q[8]?q[7:0]:~q[7:0])};
            disparity<=disparity+(q[8]?balance:-balance);
        end else if((disparity>0 && balance>0) || (disparity<0 && balance<0)) begin
            symbol<={1'b1,q[8],~q[7:0]};
            disparity<=disparity+(q[8]?2:0)-balance;
        end else begin
            symbol<={1'b0,q[8],q[7:0]};
            disparity<=disparity-(q[8]?0:2)+balance;
        end
    end
endmodule
