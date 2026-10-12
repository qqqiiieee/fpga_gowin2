// 职责：只读统计 PT8211 装载的数字 PCM，并从当前按键/弯音推算频率设定。
// clk=27MHz，rst_n 异步低有效；sample_tick 是93750Hz采样使能，不是新时钟。
// pcm 为16位二补码，幅值0..32768；每1024个采样构成统计窗口，名义10.923ms。
// peak/rms 为无符号PCM幅值（rms为均方的整数平方根），level_dbfs 为8位有符号
// 数字满幅分贝的分段近似，静音为-96；不是麦克风声压、kg或模拟信噪比。
// peak_percent 是相对32768的百分数；volume_percent 来自0..255音量控制码。
// keys bit0..11为S1..S12，busy每位是一个声部状态，voices为0..32的置位计数，
// 不把忙碌声部数当实际可闻谱峰数；pitch为9位有符号弯音码。
// primary_note 选择最低编号按住键；frequency_hz 是其 DDS 设定的整数Hz，
// 不是PCM过零测频或和弦FFT。frequency_bcd从高到低4个nibble为千/百/十/个位。
// note_valid 是当前BCD/音符元组对应的有效状态，不是单拍发布事件；无键时无效。
// peak/rms/dBFS在窗口平方根完成后保持；Hz与BCD有各自流水延迟，不是同clk快照。
// clip 在采样幅值>=32767后保持若干窗口，表示近数字满幅，不证明DAC已经削波。
// 无模块参数；统计窗/参考采样率固定。复位测量为0、dBFS=-96、note_valid=0。
// 本模块无UI暂停入口，源域计量持续运行；跟弹暂停和scope采集由各自模块负责。
module instrument_telemetry(
 input clk,input rst_n,input sample_tick,input [15:0] pcm,
 input [11:0] keys,input [7:0] volume,input signed [8:0] pitch,
 input [31:0] busy,
 output reg [15:0] peak,output reg [15:0] rms,
 output reg signed [7:0] level_dbfs,output reg [7:0] peak_percent,
 output reg [7:0] volume_percent,output reg [5:0] voices,
 output reg [6:0] primary_note,output reg note_valid,
 output reg [15:0] frequency_hz,output reg [15:0] frequency_bcd,
 output clip);
 // 8位分组成对相加，结果4位可容纳0..8；只计输入置位，不分析PCM声源。
 function [3:0] count8;
  input [7:0] v;
  reg [3:0] a,b,c,d;
  begin
   a={3'd0,v[0]}+{3'd0,v[1]};b={3'd0,v[2]}+{3'd0,v[3]};
   c={3'd0,v[4]}+{3'd0,v[5]};d={3'd0,v[6]}+{3'd0,v[7]};
   count8=(a+b)+(c+d);
  end
 endfunction
 // 用最高有效位估算每倍幅值约6dB，再按归一化高位分段修正，避免运行时对数器。
 function signed [7:0] db_value;
  input [15:0] value;
  integer i,e,loss,correction;
  reg [15:0] norm;
  begin
   e=0;norm=0;correction=0;loss=96;
   for(i=0;i<16;i=i+1)if(value[i])e=i;
   norm=value<<(15-e);
   case(norm[14:11])
    0:correction=0;1,2:correction=1;3,4,5:correction=2;
    6,7:correction=3;8,9,10:correction=4;
    11,12,13,14:correction=5;15:correction=6;
   endcase
   if(value!=0)loss=(15-e)*6-correction;
   if(loss<0)loss=0;
   db_value=-loss;
  end
 endfunction
 reg [3:0] voice0,voice1,voice2,voice3;
 reg [15:0] volume_product;
 wire [16:0] volume_quotient={1'b0,volume_product}+17'd1+
                             {9'd0,volume_product[15:8]};
 // 分组计数和音量常数乘法分开寄存，缩短组合路径；这些状态每clk刷新，不等窗口结束。
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin voice0<=0;voice1<=0;voice2<=0;voice3<=0;
    voices<=0;volume_product<=0;volume_percent<=0;end
  else begin
   voice0<=count8(busy[7:0]);voice1<=count8(busy[15:8]);
   voice2<=count8(busy[23:16]);voice3<=count8(busy[31:24]);
   voices<=({2'b0,voice0}+{2'b0,voice1})+({2'b0,voice2}+{2'b0,voice3});
   volume_product<=volume*16'd100+16'd127;
   volume_percent<=volume_quotient[15:8];
  end
 end
 reg [15:0] magnitude_q,magnitude_delay;
 reg [31:0] square_q;
 reg [1:0] tick_pipe;
 reg [40:0] square_sum;
 reg [9:0] window_count;
 reg [15:0] window_peak;
 reg [15:0] measurement_peak;
 reg [3:0] clip_windows;
 reg [31:0] mean_square;
 reg [15:0] root,trial;
 reg [31:0] trial_square;
 reg [3:0] root_bit;
 reg [1:0] root_state;
 reg root_busy;
 wire [40:0] sum_next=square_sum+{9'd0,square_q};
 wire [15:0] peak_next=(magnitude_delay>window_peak)?magnitude_delay:window_peak;
 wire [15:0] root_next=(trial_square<=mean_square)?trial:root;
 assign clip=(clip_windows!=0);
 // 幅值、平方和使能一起流水，窗口仅累积 tick_pipe 指示的采样，不能每clk重复加。
 // 完整窗口先冻结均方/峰值，再独立迭代开方；平方和用41位容纳1024个平方。
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   magnitude_q<=0;magnitude_delay<=0;square_q<=0;tick_pipe<=0;
   square_sum<=0;window_count<=0;window_peak<=0;measurement_peak<=0;peak<=0;rms<=0;
   level_dbfs<=-8'sd96;peak_percent<=0;clip_windows<=0;
   mean_square<=0;root<=0;trial<=0;trial_square<=0;root_bit<=0;root_state<=0;root_busy<=0;
  end else begin
   magnitude_q<=pcm[15]?(~pcm+16'd1):pcm;
   magnitude_delay<=magnitude_q;square_q<=magnitude_q*magnitude_q;
   tick_pipe<={tick_pipe[0],sample_tick};
   trial_square<=trial*trial;
   if(tick_pipe[1])begin
    if(magnitude_delay>=32767)clip_windows<=10;
    if(window_count==1023)begin
     window_count<=0;square_sum<=0;window_peak<=0;measurement_peak<=peak_next;
     if(clip_windows!=0 && magnitude_delay<32767)clip_windows<=clip_windows-1'b1;
     mean_square<=sum_next[40:10];root<=0;root_bit<=15;root_state<=0;root_busy<=1;
    end else begin
     window_count<=window_count+1'b1;square_sum<=sum_next;window_peak<=peak_next;
    end
   end
   // 从高位到低位试置平方根的每一位，每位留3个clk给平方寄存/比较，共48clk。
   // 不用单周期大开方组合器；当前288clk/采样预算下可在下一窗口前完成。
   if(root_busy)case(root_state)
    0:begin trial<=root | (16'h0001<<root_bit);root_state<=1;end
    1:root_state<=2;
    2:begin
     root<=root_next;
     if(root_bit==0)begin
      rms<=root_next;level_dbfs<=db_value(root_next);root_busy<=0;
      peak<=measurement_peak;
      peak_percent<=(measurement_peak*24'd100+24'd16384)>>15;
     end
     else begin root_bit<=root_bit-1'b1;root_state<=0;end
    end
    default:root_state<=0;
   endcase
  end
 end
 // 从最低编号保持键查音符设定，未按键输出无效；尾音仍可能响而此设定已无效。
 reg [6:0] selected_note;
 reg selected_valid,found;
 integer k;
 // 映射与演奏键盘一致，S1..S12是白键排列，并非连续12个半音。
 function [6:0] mapped_note;
  input integer index;
  begin case(index)
   0:mapped_note=60;1:mapped_note=62;2:mapped_note=64;3:mapped_note=65;
   4:mapped_note=67;5:mapped_note=69;6:mapped_note=71;7:mapped_note=72;
   8:mapped_note=74;9:mapped_note=76;10:mapped_note=77;11:mapped_note=79;
   default:mapped_note=0;
  endcase end
 endfunction
 always @*begin
  selected_note=0;selected_valid=0;found=0;
  for(k=0;k<12;k=k+1)if(keys[k]&&!found)begin
   selected_note=mapped_note(k);selected_valid=1;found=1;
  end
 end
 wire [23:0] base_increment;
 note_table u_frequency(selected_note,base_increment);
 reg signed [22:0] bend_delta_q;
 reg [23:0] base_q,bent_q;
 reg [47:0] hz_product_q;
 reg [3:0] note_valid_pipe;
 reg [6:0] note_q0,note_q1,note_q2,frequency_note;
 reg frequency_valid;
 wire [47:0] rounded_hz=hz_product_q+48'd8388608;
 // 重用合成器的弯音近似公式；音符、有效位、增量和乘积各自按clk流水传递。
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin bend_delta_q<=0;
   base_q<=0;bent_q<=0;hz_product_q<=0;frequency_hz<=0;note_valid_pipe<=0;
   note_q0<=0;note_q1<=0;note_q2<=0;frequency_note<=0;frequency_valid<=0;end
  else begin
   note_q0<=selected_note;note_q1<=note_q0;note_q2<=note_q1;
   frequency_note<=note_q2;frequency_valid<=note_valid_pipe[2];
   note_valid_pipe<={note_valid_pipe[2:0],selected_valid};
   base_q<=base_increment;
   bend_delta_q<=$signed({1'b0,base_increment[23:11]})*pitch;
   bent_q<=base_q+{bend_delta_q[22],bend_delta_q};
   hz_product_q<=bent_q*48'd93750;
   frequency_hz<=note_valid_pipe[2]?rounded_hz[39:24]:16'd0;
  end
 end
 reg [31:0] decimal_shift,decimal_adjust;
 reg [4:0] decimal_count;
 reg decimal_busy;
 reg [15:0] converted_hz;
 reg [6:0] converted_note;
 reg converted_valid;
 integer digit;
 // 移位加3将16位整数转换为4位BCD：一次转换16clk，转换期间锁住待转换元组。
 always @*begin
  decimal_adjust=decimal_shift;
  for(digit=0;digit<4;digit=digit+1)
   if(decimal_shift[16+digit*4 +:4]>=5)
    decimal_adjust[16+digit*4 +:4]=decimal_shift[16+digit*4 +:4]+4'd3;
 end
 // 输入Hz/音符/有效状态改变才启动转换，完成时共同发布BCD、primary_note和note_valid。
 // 如果输入在转换中改变，当前转换先完成，下次空闲再追踪新元组。
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin decimal_shift<=0;decimal_count<=0;decimal_busy<=0;
   converted_hz<=16'hffff;frequency_bcd<=0;converted_note<=0;converted_valid<=0;
   primary_note<=0;note_valid<=0;end
  else if(!decimal_busy)begin
   if(frequency_hz!=converted_hz || frequency_note!=converted_note || frequency_valid!=converted_valid)begin
    converted_hz<=frequency_hz;decimal_shift<={16'd0,frequency_hz};decimal_count<=0;decimal_busy<=1;
    converted_note<=frequency_note;converted_valid<=frequency_valid;
   end
  end else begin
   decimal_shift<=decimal_adjust<<1;
   if(decimal_count==15)begin
    frequency_bcd<=decimal_adjust[30:15];decimal_busy<=0;
    primary_note<=converted_note;note_valid<=converted_valid;
   end
   else decimal_count<=decimal_count+1'b1;
  end
 end
endmodule
