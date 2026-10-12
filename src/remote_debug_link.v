// 模块职责：接收完整且校验通过的16字节UART虚拟输入命令，原子更新控制状态，
// 回传16字节ACK；远程控制超时后自动撤销，避免断线后虚拟键永久按住。
// 时钟/复位：clk 默认为27MHz，rst_n 为异步低有效复位；UART默认为115200、
// 8N1（1起始低位、8数据位LSB先传、无奇偶校验、1停止高位），空闲TX为高。
// CLK_HZ/BAUD 单位为Hz/bit每秒；TIMEOUT_CYCLES为clk周期，默认27000000=1秒。
// 端口：uart_rx/uart_tx 为串行逻辑线；physical_keys 是16位物理键状态，
// physical_adc 为4个16位ADC字，低到高依次A0/A1压力、A2音量、A3音高。
// 本工程 physical_keys 接有效 key_state；退出虚拟模式后的数个消抖扫描周期
// 可能仍回显旧键位，不是第二套独立物理扫描器；查询时应考虑该消抖延迟。
// status_flags 由输入层提供：bit7=合成overrun，bit6=鬼键，bit5=滑杆ready，
// bit4=有效ADC数据过期，bit3=实体ADC故障；ACK保留这些位。
// remote_active/zero_mode/park_i2c 为持续控制请求，实际切换输入、输出纯零和
// 停驻I2C由上层实施。virtual_keys 每位取1为按下；velocity为8位无单位力度量；
// virtual_adc 的通道打包同physical_adc，模拟±4.096V量程下125uV/码的非负输入，
// 每路限制在26400码（约3.3V）。accepted 为有效命令单拍，last_seq 保存其8位序号。
// 输入命令字节索引（均为十六进制帧头、其余原始二进制，不是ASCII文本）：
// [0]=A5 [1]=5A [2]=seq [3]=flags [4]=keys低 [5]=keys高 [6]=velocity
// [7,8]=A0低/高 [9,10]=A1低/高 [11,12]=A2低/高 [13,14]=A3低/高
// [15]=XOR([2]..[14])；flags bit0启用远程、bit1请求纯零、bit2停驻I2C，
// bit7..3必须为0。bit1/2仅在bit0=1时生效；seq只回显/记录，不去重或排序。
// ACK字节索引：[0]=5A [1]=A5 [2]=08 [3]=seq [4]=有效flags
// [5]=keys低 [6]=keys高 [7..14]=A0..A3各低/高 [15]=XOR([2]..[14])。
// ACK的08是通信协议版本字段，不是固件版本号；ACK没有velocity字段。
// ACK有效flags高5位来自status_flags，低3位来自已接受的远程请求（禁用时全0）。
// 启用命令ACK回虚拟keys/限幅ADC；禁用命令ACK回本拍物理keys/ADC快照。
// 接收/组包/发送是三个独立时序过程：起始位中心确认 -> 8位采样 -> 停止位验证；
// 搜帧头 -> 累积13个字段 -> 校验并提交；ACK锁存 -> 逐字节8N1发送。
// ACK发送时不接受新包，没有接收命令队列；主机应等ACK完整结束后再发下一条。
// 无外部 clock enable，RX/TX 位计时及两个超时器按每个 clk 工作。
// CLK_HZ/BAUD 须为正且算出的 BIT_CYCLES 至少1；各计时门槛需在32位计数范围，
// TIMEOUT_CYCLES 也须为正，代码不自动钳位；默认值对应本工程27MHz配置。
// 复位保持TX空闲高、实体模式、velocity=160；缓存ADC/序号本身不表示仍有新数据。
// Bounded, acknowledged virtual-input link. UART 115200 8N1 at 27 MHz.
// A5 5A seq flags keysLE velocity ADC0..3LE XOR(bytes2..14).
// Reply: 5A A5 08 seq flags keysLE ADC0..3LE XOR(bytes2..14).
// No input becomes active until a complete valid command has been received.
module remote_debug_link #(
  parameter CLK_HZ=27000000,
  parameter BAUD=115200,
  parameter TIMEOUT_CYCLES=27000000
)(
  input clk,input rst_n,input uart_rx,output reg uart_tx,
  input [15:0] physical_keys,input [63:0] physical_adc,input [7:0] status_flags,
  output reg remote_active,output reg zero_mode,output reg park_i2c,
  output reg [15:0] virtual_keys,output reg [7:0] velocity,
  output reg [63:0] virtual_adc,output reg accepted,output reg [7:0] last_seq
);
  // 对一个UART位的周期数四舍五入；默认取234周期，实际波特率约115385。
  localparam BIT_CYCLES=(CLK_HZ+BAUD/2)/BAUD;
  localparam HALF_CYCLES=(BIT_CYCLES<2)?1:(BIT_CYCLES/2);
  // 残包等待上限取20ms与12个位时间中的较大者；packet_age 每个完整收到的
  // 字节清0，因此这是包内字节间超时，不是整包总时长，也不是1秒远程watchdog。
  localparam FRAGMENT_CYCLES=((CLK_HZ/50)>BIT_CYCLES*12)?(CLK_HZ/50):(BIT_CYCLES*12);
  reg rx_meta,rx_sync;
  reg [2:0] rx_state;
  reg [31:0] rx_timer;
  reg [2:0] rx_bit;
  reg [7:0] rx_shift,rx_data;
  reg rx_valid,rx_error;
  // RX异步输入两级同步；rx_valid/rx_error 默认每拍清0，仅完整字节/错误时脉冲。
  // rx_state：0等低起始、1半位确认、2数据中心采样、3停止位、4等待break结束。
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      rx_meta<=1;rx_sync<=1;rx_state<=0;rx_timer<=0;rx_bit<=0;
      rx_shift<=0;rx_data<=0;rx_valid<=0;rx_error<=0;
    end else begin
      rx_meta<=uart_rx;rx_sync<=rx_meta;rx_valid<=0;rx_error<=0;
      case(rx_state)
        0: if(!rx_sync) begin rx_timer<=HALF_CYCLES-1;rx_state<=1;end
        // 半位后若已回高则视为毛刺；仍为低才开始按整位间隔采样8位数据。
        1: if(rx_timer!=0) rx_timer<=rx_timer-1'b1;
           else if(!rx_sync) begin rx_timer<=BIT_CYCLES-1;rx_bit<=0;rx_state<=2;end
           else rx_state<=0;
        2: if(rx_timer!=0) rx_timer<=rx_timer-1'b1;
           else begin
             rx_shift[rx_bit]<=rx_sync;rx_timer<=BIT_CYCLES-1;
             if(rx_bit==7) rx_state<=3;else rx_bit<=rx_bit+1'b1;
           end
        // 停止位必须为高；为低则报帧错误，持续低break期间不继续伪造接收字节。
        3: if(rx_timer!=0) rx_timer<=rx_timer-1'b1;
           else if(rx_sync) begin rx_data<=rx_shift;rx_valid<=1;rx_state<=0;end
           else begin rx_error<=1;rx_state<=4;end
        4: if(rx_sync) rx_state<=0; // Do not interpret a serial break as a packet.
        default:rx_state<=0;
      endcase
    end
  end

  // 虚拟ADC按无符号非负输入处理：超过26400一律截到26400。
  // 这不等同于压力/滑条模块的负码置0；若主机发送二补码负数，它在这里被当作
  // 大无符号数而限到上限。主机应按协议发送0..26400，不能发送负电压编码。
  function [15:0] clamp_adc;
    input [15:0] raw;
    begin clamp_adc=(raw>16'd26400)?16'd26400:raw;end
  endfunction
  // 组装固定16字节回复，最低8位是线上最先发送的字节；16位键/ADC自然按
  // 低字节在前打包。XOR包括协议版本08、seq、flags、keys、ADC，不包括两字节帧头。
  function [127:0] make_reply;
    input [7:0] seq,flags;
    input [15:0] keys;
    input [63:0] adc;
    reg [127:0] value;reg [7:0] check;integer i;
    begin
      // 此08只标记这套ACK字段布局的协议版本，与工程V008命名没有绑定逻辑。
      value=0;value[7:0]=8'h5a;value[15:8]=8'ha5;value[23:16]=8'h08;
      value[31:24]=seq;value[39:32]=flags;
      value[55:40]=keys;value[119:56]=adc;
      check=0;for(i=2;i<15;i=i+1) check=check^value[i*8 +: 8];
      value[127:120]=check;make_reply=value;
    end
  endfunction

  reg [7:0] packet[0:15];
  reg [4:0] packet_count;
  reg [7:0] packet_xor;
  reg [31:0] packet_age,watchdog;
  reg ack_start;
  reg [127:0] ack_payload;
  // 输入每路ADC小端重组后分别限幅；拼接最高字为A3，最低字为A0。
  wire [63:0] requested_adc={clamp_adc({packet[14],packet[13]}),
    clamp_adc({packet[12],packet[11]}),clamp_adc({packet[10],packet[9]}),
    clamp_adc({packet[8],packet[7]})};
  wire [15:0] requested_keys={packet[5],packet[4]};
  // ACK高5位保留上层状态，低3位反映本次有效请求，不直接回显原始status低3位。
  wire [7:0] requested_flags=(status_flags & 8'hf8) |
    (packet[3][0]?{5'b00000,packet[3][2:0]}:8'd0);

  reg tx_frame_busy;
  reg [127:0] tx_frame;
  reg [1:0] tx_state;
  reg [31:0] tx_timer;
  reg [3:0] tx_byte;
  reg [2:0] tx_bit;
  // 组包与控制状态提交：复位/残包/校验失败均不会提前激活半套虚拟输入。
  // packet数组本身不复位，但packet_count从0开始；只有字段2..14全部被本次
  // 完整帧写过且校验通过才读取它们提交，未完成的旧内容不对外生效。
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      remote_active<=0;zero_mode<=0;park_i2c<=0;virtual_keys<=0;
      velocity<=160;virtual_adc<=0;accepted<=0;last_seq<=0;
      packet_count<=0;packet_xor<=0;packet_age<=0;watchdog<=0;
      ack_start<=0;ack_payload<=0;
    end else begin
      accepted<=0;ack_start<=0;
      if(remote_active) begin
        // watchdog按系统时钟计距上次已接受命令的时间，仅remote_active期间运行。
        // 到1秒撤销远程/纯零/停驻及虚拟键；velocity/virtual_adc/last_seq仍保留，
        // 是否使用这些保留值取决于上层remote_active选择，不在此自动发送超时ACK。
        if(watchdog>=TIMEOUT_CYCLES-1) begin
          remote_active<=0;zero_mode<=0;park_i2c<=0;virtual_keys<=0;watchdog<=0;
        end else watchdog<=watchdog+1'b1;
      end else watchdog<=0;
      if(packet_count!=0) packet_age<=packet_age+1'b1;else packet_age<=0;
      // TX占用或ACK启动脉冲期间清组包进度，不排队；RX帧错误或字节间超时同样
      // 丢弃残包，但不立刻撤销已接受的远程控制，该控制仍由1秒watchdog约束。
      if(tx_frame_busy || ack_start || rx_error ||
         (packet_count!=0 && packet_age>=FRAGMENT_CYCLES-1)) begin
        packet_count<=0;packet_xor<=0;packet_age<=0;
      end else if(rx_valid) begin
        packet_age<=0;
        case(packet_count)
          // 第一帧头A5后若又来A5，保持等待5A，可从连续A5中重新找帧头。
          // 帧头不写入packet数组、不参与XOR；随后仅累积索引2..14的字段。
          0: if(rx_data==8'ha5) begin packet_count<=1;packet_xor<=0;end
          1: if(rx_data==8'h5a) packet_count<=2;
             else if(rx_data!=8'ha5) packet_count<=0;
          15: begin
            // 第16字节是校验，不再参与累积；同时检查flags保留高位为0。
            // XOR或flags非法的帧静默丢弃，无accepted、无ACK，也不重置watchdog。
            packet_count<=0;packet_xor<=0;
            if(rx_data==packet_xor && packet[3][7:3]==0) begin
              // 单一提交点同时刷新全部字段，避免键与ADC来自不同半帧。
              // 若本拍也到watchdog门槛，靠后的本分支赋值优先，合法新命令立即接管。
              remote_active<=packet[3][0];
              zero_mode<=packet[3][0] && packet[3][1];
              park_i2c<=packet[3][0] && packet[3][2];
              virtual_keys<=packet[3][0]?requested_keys:16'd0;
              // 即使bit0关闭，仍保存请求力度/限幅ADC，但虚拟键和控制请求被撤销。
              velocity<=packet[6];virtual_adc<=requested_adc;
              watchdog<=0;accepted<=1;last_seq<=packet[2];
              // 回复用本次请求构建，不读取尚未更新的remote_active/virtual_*；
              // bit0关闭时改用这一clk边沿采到的物理快照，ACK发出期间不再变化。
              ack_payload<=make_reply(packet[2],requested_flags,
                packet[3][0]?requested_keys:physical_keys,
                packet[3][0]?requested_adc:physical_adc);
              ack_start<=1;
            end
          end
          default: begin
            packet[packet_count]<=rx_data;packet_xor<=packet_xor^rx_data;
            packet_count<=packet_count+1'b1;
          end
        endcase
      end
    end
  end

  // One whole reply is latched. Incoming packets are ignored until its stop bit.
  // TX将整个ACK一次锁存；tx_state=0空闲/起始，1发送8位，2进入停止位，
  // 3保持停止位再换字节。每字节10个位时间，无校验位和额外字节间隙。
  // 最后一个停止位保持满BIT_CYCLES才清tx_frame_busy，组包才可恢复。
  always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      uart_tx<=1;tx_frame_busy<=0;tx_frame<=0;tx_state<=0;
      tx_timer<=0;tx_byte<=0;tx_bit<=0;
    end else case(tx_state)
      0: if(ack_start) begin
        tx_frame<=ack_payload;tx_frame_busy<=1;tx_byte<=0;tx_bit<=0;
        uart_tx<=0;tx_timer<=BIT_CYCLES-1;tx_state<=1;
      end
      1: if(tx_timer!=0) tx_timer<=tx_timer-1'b1;
         else begin
            // tx_byte从0..15顺序发送，tx_bit从0..7，故字节序和位序均为低位先发。
           uart_tx<=tx_frame[tx_byte*8+tx_bit];tx_timer<=BIT_CYCLES-1;
           if(tx_bit==7) tx_state<=2;else tx_bit<=tx_bit+1'b1;
         end
      2: if(tx_timer!=0) tx_timer<=tx_timer-1'b1;
         else begin uart_tx<=1;tx_timer<=BIT_CYCLES-1;tx_state<=3;end
      3: if(tx_timer!=0) tx_timer<=tx_timer-1'b1;
         else if(tx_byte==15) begin uart_tx<=1;tx_frame_busy<=0;tx_state<=0;end
         else begin
           tx_byte<=tx_byte+1'b1;tx_bit<=0;uart_tx<=0;
           tx_timer<=BIT_CYCLES-1;tx_state<=1;
         end
      default: begin uart_tx<=1;tx_frame_busy<=0;tx_state<=0;end
    endcase
  end
endmodule
