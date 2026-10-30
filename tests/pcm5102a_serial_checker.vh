// 独立接收器：只观察端口/装载使能，不读取DUT的计数器或移位器。
// I2S在LRCK翻转沿完成上一字，下一BCK上升沿才接收新字MSB。
module pcm5102a_serial_checker(
 input clk,rst_n,tick,input [15:0] pcm,
 input bck,lrck,din,input hp_bck,hp_ws,hp_din,
 output integer words=0,output integer nonzero_words=0);
 reg [15:0] latest=0,expect_i=0,expect_h=0,word_i=0,word_h=0;
 reg active_i=0,old_lr=0;
 integer ibits=0,hbits=0,cycles=0,last_tick=0,last_rise=0,last_edge=0;
 integer loaded=0;
 reg old_bck=0,old_din=0,old_ws=0;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n)begin latest=0;loaded=0;end
  else if(tick)begin latest=pcm;loaded=loaded+1;end
 end
 always @(posedge bck or negedge rst_n) begin
  if(!rst_n)begin
   active_i=0;old_lr=0;ibits=0;word_i=0;expect_i=0;words=0;nonzero_words=0;
  end else begin
   if(active_i)begin
    word_i={word_i[14:0],din};ibits=ibits+1;
    if(ibits==16)begin
     if(word_i!==expect_i)$fatal(1,"I2S word mismatch got=%h expected=%h",word_i,expect_i);
     words=words+1;if(word_i!=0)nonzero_words=nonzero_words+1;
     active_i=0;
    end
   end
   if(lrck!==old_lr)begin
    if(active_i)$fatal(1,"I2S LRCK changed before full 16-bit word");
    active_i=1;ibits=0;word_i=0;expect_i=latest;
   end
   old_lr=lrck;
   if(loaded==0 && din!==0)$fatal(1,"I2S nonzero before first frame load");
  end
 end
 // 原右对齐PT8211接收器：每半帧从第一个上升沿收16位。
 always @(posedge hp_bck or negedge rst_n) begin
  if(!rst_n)begin hbits=0;word_h=0;expect_h=0;end
  else begin
   if(hbits==0)expect_h=latest;
   word_h={word_h[14:0],hp_din};hbits=hbits+1;
   if(hbits==16)begin
    if(word_h!==expect_h)$fatal(1,"PT8211 word changed got=%h expected=%h",word_h,expect_h);
    hbits=0;
   end
  end
 end
 // 使用主时钟周期检查采样节奏、两输出相位、占空比和数据建立时间。
 always @(posedge clk)begin
  if(!rst_n)begin cycles=0;last_tick=0;last_rise=0;last_edge=0;end
  else begin
   cycles=cycles+1;
   if(tick)begin
    if(last_tick!=0 && cycles-last_tick!=288)$fatal(1,"sample cadence changed");
    last_tick=cycles;
   end
  end
  #1;
  if(!rst_n)begin old_bck=0;old_din=0;old_ws=0;end
  else begin
   if({bck,lrck}!={hp_bck,hp_ws})$fatal(1,"I2S/PT8211 clocks not aligned");
   if((^{bck,lrck,din,hp_bck,hp_ws,hp_din})===1'bx)$fatal(1,"unknown serial output");
   if((din!==old_din || lrck!==old_ws) && !(old_bck && !bck))
    $fatal(1,"I2S data/word-select changed outside falling BCK edge");
   if(bck!=old_bck)begin
    if(last_edge!=0 && cycles-last_edge!=(bck?4:5))$fatal(1,"BCK pulse width");
    last_edge=cycles;
    if(bck)begin
     if(last_rise!=0 && cycles-last_rise!=9)$fatal(1,"BCK period");
     last_rise=cycles;
    end
   end
   old_bck=bck;old_din=din;old_ws=lrck;
  end
 end
endmodule
