// V021全局旋律/打击乐平衡：音量控制与声部合成仍在FPGA中完成。
// 四鼓先用18位有符号求和后除4，保留四路同时峰值的数字余量；
// 再将旋律和鼓组以互补Q8权重混合，权重总和恒为256，不靠截断回绕限幅。
// tick为每帧一次的采样使能。处理管线4个clk，输出下一个tick之前已稳定。
// balance=0只留旋律，255几乎只留鼓；128各半。目标每帧最多移动1码，避免旋钮拉链声。
module performance_mixer(
 input clk,input rst_n,input tick,input [15:0] melody,kick,snare,closed_hat,open_hat,
 input [7:0] balance,output reg [15:0] sample
);
 reg [7:0] balance_smooth;
 reg signed [17:0] drums_q;
 reg signed [15:0] melody_q;
 reg signed [25:0] melody_product,drums_product;
 reg signed [26:0] total_q;
 reg [3:0] valid;
 wire signed [17:0] drums_sum=$signed({{2{kick[15]}},kick})+
    $signed({{2{snare[15]}},snare})+$signed({{2{closed_hat[15]}},closed_hat})+
    $signed({{2{open_hat[15]}},open_hat});
 wire signed [9:0] melody_gain=10'sd256-$signed({2'b00,balance_smooth});
 wire signed [9:0] drums_gain=$signed({2'b00,balance_smooth});
 wire signed [26:0] scaled=total_q>>>8;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n)begin
   balance_smooth<=128;drums_q<=0;melody_q<=0;melody_product<=0;
   drums_product<=0;total_q<=0;sample<=0;valid<=0;
  end else begin
   valid<={valid[2:0],tick};
   if(tick)begin
    if(balance_smooth<balance)balance_smooth<=balance_smooth+1'b1;
    else if(balance_smooth>balance)balance_smooth<=balance_smooth-1'b1;
    drums_q<=drums_sum>>>2;melody_q<=$signed(melody);
   end
   if(valid[0])begin
    melody_product<=melody_q*melody_gain;
    drums_product<=drums_q*drums_gain;
   end
   if(valid[1])total_q<=$signed(melody_product)+$signed(drums_product);
   if(valid[2])sample<=scaled>32767?16'h7fff:(scaled< -32768?16'h8000:scaled[15:0]);
  end
 end
endmodule
