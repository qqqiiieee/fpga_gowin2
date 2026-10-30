// PCM5102A 三线标准 I2S：27MHz / 9 / 32 = 93750Hz，16位二补码，单声道复制到L/R。
// 所有逻辑由clk驱动；BCK不是内部时钟，不引入PLL、重采样或音量变换。
// 与pt8211_driver使用相同复位/分频/帧相位，在同一288clk边界锁存同一PCM。
// 两个串口的BCK/LRCK相位一致，但I2S的MSB必须比LRCK翻转晚一个BCK：
// 位槽0是上一帧R的LSB；1..16是本帧L的bit15..0；17..31是本帧R的bit15..1。
// 本帧R的bit0跨到下一帧位槽0。因此LRCK翻转的那个上升沿仍采上一声道的LSB，
// 不能把该位强制补0，也不能在slot31提前覆盖右通道移位器。
// LRCK=0预告左声道，1预告右声道；接收器在BCK上升沿采样。
// BCK高5clk/低4clk；DIN/LRCK仅在BCK下降沿更新。复位时全部清0。
// PCM5102A：FMT=0，SCK接GND启用BCK PLL，XSMT=3.3V，DEMP=0。
module pcm5102a_i2s(
    input clk,input rst_n,input [15:0] sample,
    output bck,output lrck,output din);
    reg [3:0] div_count;
    reg [4:0] bit_index;
    reg [15:0] frame_sample,shift_reg;
    reg bck_r;
    assign bck=bck_r;
    assign lrck=bit_index[4];
    assign din=shift_reg[15];
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            div_count<=0;bit_index<=0;frame_sample<=0;shift_reg<=0;bck_r<=0;
        end else if(div_count==8) begin
            div_count<=0;bit_index<=bit_index+1'b1;bck_r<=0;
            // 保持PT8211原帧装载时刻。另一个模块在本沿更新的PCM按NBA规则
            // 要到下一帧才可见，左右通道均使用本帧缓存，避免跨帧撕裂。
            if(bit_index==31) frame_sample<=sample;
            if(bit_index==0 || bit_index==16) shift_reg<=frame_sample;
            else shift_reg<={shift_reg[14:0],1'b0};
        end else begin
            div_count<=div_count+1'b1;
            if(div_count==3) bck_r<=1;
        end
    end
endmodule
