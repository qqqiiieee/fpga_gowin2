// 数字PCM示波支路，256个相邻绘图点对，4:1抽取，窗口约10.9ms（Fs93750）。
// source_clk通常27MHz；sample_tick只使能采样。pixel域25.2MHz同步读BRAM一拍。
// pcm/current/previous均为16bit二补码；read_addr为0..255；valid=0时输出数字零。
// TRIGGER_TIMEOUT默认512个采样（约5.46ms），非零输入等待负到正过零或超时。
// 512×32bit RAM分成两银行；源域只能写请求对应的背银行，显示银行一帧内保持不变。
// req/ack切换同时绑定capture_gain与该银行，保证响音开始时不会套用旧静音增益。
// scope_gain=0..4是绘图左移量，仅改变显示，不改变声音或真实测量单位。
// COMMIT在末次write_enable实际写入后的下一拍应答，不能提前切银行。
// 本波形是数字DAC装载前PCM，不采DIN/BCLK，不能证明模拟输出底噪已消失。

// 256 real PCM sample pairs, 4:1 decimation (~10.9ms span). Zero-cross trigger.
// Source writes only the back bank; pixel swaps only after ack at a frame edge.
// RAM and metadata remain immutable while displayed. Never samples DIN/BCLK.
module wave_scope #(parameter TRIGGER_TIMEOUT=512)(
 input source_clk,input source_rst_n,input sample_tick,input [15:0] pcm,
 input pixel_clk,input pixel_rst_n,input frame_start,
 input [7:0] read_addr,
 output signed [15:0] wave_current,wave_previous,
 output reg [3:0] scope_gain,output reg valid);
 reg [31:0] samples [0:511] /* synthesis syn_ramstyle="block_ram" */;
 reg request,ack,front_bank,outstanding;
 (* syn_preserve=1 *) reg req_meta,req_sync,ack_meta,ack_sync;
 reg [3:0] capture_gain;
 reg [31:0] read_q;
 reg write_enable;
 reg [8:0] write_addr;
 reg [31:0] write_data;
 always @(posedge source_clk)if(write_enable)samples[write_addr]<=write_data;
 always @(posedge pixel_clk)read_q<=samples[{front_bank,read_addr}];
 assign wave_current=valid?$signed(read_q[15:0]):16'sd0;
 assign wave_previous=valid?$signed(read_q[31:16]):16'sd0;
 always @(posedge pixel_clk or negedge pixel_rst_n)begin
  if(!pixel_rst_n)begin request<=0;ack_meta<=0;ack_sync<=0;
   front_bank<=0;outstanding<=0;scope_gain<=0;valid<=0;end
  else begin
   ack_meta<=ack;ack_sync<=ack_meta;
   if(frame_start && request==ack_sync)begin
    if(outstanding)begin front_bank<=ack_sync;scope_gain<=capture_gain;valid<=1;end
    request<=!request;outstanding<=1;
   end
  end
 end
 localparam IDLE=0,WAIT_EDGE=1,CAPTURE=2,COMMIT=3;
 reg [1:0] state,decimation;
 reg [7:0] index;
 reg [15:0] wait_samples,previous_pcm,previous_point;
 reg write_bank;
 reg [15:0] capture_peak;
 wire [15:0] magnitude=pcm[15]?(~pcm+16'd1):pcm;
 wire trigger=pcm==0 || (previous_pcm[15] && !pcm[15]) ||
              wait_samples>=TRIGGER_TIMEOUT-1;
 always @(posedge source_clk or negedge source_rst_n)begin
  if(!source_rst_n)begin
   req_meta<=0;req_sync<=0;ack<=0;state<=IDLE;decimation<=0;
   index<=0;wait_samples<=0;previous_pcm<=0;previous_point<=0;
   write_bank<=0;capture_gain<=0;capture_peak<=0;write_enable<=0;write_addr<=0;write_data<=0;
  end else begin
   req_meta<=request;req_sync<=req_meta;write_enable<=0;
   if(sample_tick)previous_pcm<=pcm;
   case(state)
    IDLE:if(req_sync!=ack)begin
     write_bank<=req_sync;wait_samples<=0;capture_peak<=0;state<=WAIT_EDGE;
    end
    WAIT_EDGE:if(sample_tick)begin
     if(trigger)begin
      write_enable<=1;write_addr<={write_bank,8'd0};write_data<={pcm,pcm};
      previous_point<=pcm;index<=1;decimation<=0;state<=CAPTURE;
      capture_peak<=magnitude;
     end else wait_samples<=wait_samples+1'b1;
    end
    CAPTURE:if(sample_tick)begin
     if(magnitude>capture_peak)capture_peak<=magnitude;
     decimation<=decimation+1'b1;
     if(decimation==3)begin
      write_enable<=1;write_addr<={write_bank,index};write_data<={previous_point,pcm};
      previous_point<=pcm;index<=index+1'b1;
      if(index==255)state<=COMMIT;
     end
    end
    COMMIT:begin
     // Gain describes this exact bank, including samples between plotted points.
     // Keep ~60 pixels of headroom; no stale quiet-window gain on a loud attack.
     if(capture_peak==0 || capture_peak>=15360)capture_gain<=0;
     else if(capture_peak>=7680)capture_gain<=1;
     else if(capture_peak>=3840)capture_gain<=2;
     else if(capture_peak>=1920)capture_gain<=3;
     else capture_gain<=4;
     ack<=write_bank;state<=IDLE;
    end
   endcase
  end
 end
endmodule
