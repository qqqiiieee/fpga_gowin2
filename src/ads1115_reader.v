// 模块职责：轮询 ADS1115 单次转换，组合完整的两个转换字节后发布样本；
// 任一字节出错就丢弃整次转换，经等待和总线恢复后从 A0 重新开始。
// 通道约定：A0/A1 为两路压力，A2 为总音量，A3 为旋律音高控制。
// 本模块仅给出通道号和原始 ADC 码，不计算压力触发、音量或音高。
// ADC 码也不是 kg：由电压推导力/质量还需要传感器、模拟前端和实际标定。
// 端口：clk 为系统时钟；rst_n 为异步低有效复位；scl/sda 为带外部上拉的
// I2C 双向线。sample_valid 为一个 clk 周期的样本脉冲，sample_channel 为
// 0..3 的 AIN 编号，sample_data 为 ADS1115 16 位二补码，fault 为故障状态。
// fault 复位置 1，只有完整读数且最终 STOP 成功才清 0；不是单拍错误脉冲。
// 时序参数均以 clk 周期计：默认按 27MHz 使用，I2C_QUARTER=68 对应约
// 100kHz；CONVERT_CYCLES=40500 为 1.5ms，RETRY_CYCLES 为 100ms，
// BYTE_TIMEOUT_CYCLES 为每条字节命令/整次恢复各自的 10ms 超时上限。
// 配置为单端输入、ADC 量程 ±4.096V、860SPS，1 LSB=4.096V/32768=125uV。
// 量程并不表示可把输入接到 ±4.096V：本系统 3.3V 信号实际最大约 26400 码；
// A0..A3 的预期有效码为非负。这里原样传递符号位，不在读取端限幅。
// 状态机：RECOVER_ISSUE/WAIT -> ISSUE/WAIT_BYTE -> CONVERT -> 读寄存器；
// 错误经 DELAY 后再恢复。复位只复位 FPGA 逻辑，不能复位外部 ADC。
// 无外部 clock enable，状态机每个 clk 推进；I2C 节拍由下层计数器产生。
// PRESSURE_PRIORITY/PRESSURE_ONLY 默认均为0，作为布尔选项；ONLY 优先。
// 时间参数须为正并落在计数器可计范围；I2C_QUARTER/字节超时还受下层
// 16/24位计数器约束。缩短转换等待须依据 ADC 转换时序，不能视为已验证加速。
// ADS1115 ADDR=GND (0x48), AIN0..3 single-ended, +/-4.096V, 860 SPS.
// Start each single conversion, wait >=1.5ms, then read register 0.
module ads1115_reader #(
    parameter I2C_QUARTER=68, parameter CONVERT_CYCLES=40500,
    parameter RETRY_CYCLES=2700000,parameter PRESSURE_PRIORITY=0,
    parameter PRESSURE_ONLY=0, parameter BYTE_TIMEOUT_CYCLES=270000
)(input clk,input rst_n,inout scl,inout sda,
  output reg sample_valid,output reg [1:0] sample_channel,
  output reg [15:0] sample_data,output reg fault);
    localparam RECOVER_ISSUE=0,RECOVER_WAIT=1,DELAY=2,ISSUE=3,WAIT_BYTE=4,CONVERT=5;
    reg [2:0] state;
    reg [31:0] timer;
    reg [1:0] channel;
    reg [2:0] schedule_step;
    reg reading;
    reg [3:0] step;
    reg command_valid;
    reg [1:0] command;
    reg [7:0] tx;
    reg read_nack;
    reg [7:0] high_byte,low_byte;
    wire busy,done,byte_error;
    wire [7:0] rx;
    reg recovery_start,byte_enable;
    // 两个引擎均只能拉低或释放 SCL/SDA，绝不能强推高电平。
    // byte_enable 是寄存的总线所有权：恢复/重试时字节引擎持续复位并释放线，
    // 避免它停留在 SCL 拉低状态而阻碍恢复引擎的九个物理时钟脉冲。
    wire recovery_busy,recovery_done,recovery_error;
    // Exclusive bus ownership: reset releases the byte engine's open drains
    // throughout recovery/retry. A reset of this reader never resets the slave.
    // Registered ownership avoids combinational FSM-decode glitches on reset.
    wire byte_rst_n=rst_n && byte_enable;
    i2c_bus_recovery #(.QUARTER_CYCLES(I2C_QUARTER),
      .TIMEOUT_CYCLES(BYTE_TIMEOUT_CYCLES)) recovery(
      .clk(clk),.rst_n(rst_n),.start(recovery_start),.busy(recovery_busy),
      .done(recovery_done),.error(recovery_error),.scl(scl),.sda(sda));
    i2c_byte_master #(.QUARTER_CYCLES(I2C_QUARTER),
      .TIMEOUT_CYCLES(BYTE_TIMEOUT_CYCLES)) bus(
      .clk(clk),.rst_n(byte_rst_n),.cmd_valid(command_valid),.cmd(command),
      .tx_data(tx),.read_nack(read_nack),.busy(busy),.done(done),
      .error(byte_error),.rx_data(rx),.scl(scl),.sda(sda));
    // 主状态机只在底层 done 到达后推进 step；每次 ISSUE 仅发一个命令脉冲。
    // 接收高/低字节期间不对外发布，最终 STOP 的完成才提交整个样本。
    always @(posedge clk or negedge rst_n) begin
      if(!rst_n) begin
        state<=RECOVER_ISSUE;timer<=0;channel<=0;schedule_step<=0;reading<=0;step<=0;
        recovery_start<=0;byte_enable<=0;
        command_valid<=0;command<=0;tx<=0;read_nack<=1;high_byte<=0;low_byte<=0;
        sample_valid<=0;sample_channel<=0;sample_data<=0;fault<=1;
      end else begin
        // 三个 valid/start 均默认清零，再由对应分支置位，形成单拍握手。
        command_valid<=0;recovery_start<=0;sample_valid<=0;
        case(state)
          RECOVER_ISSUE: if(!recovery_busy) begin
            recovery_start<=1;state<=RECOVER_WAIT;
          end
          RECOVER_WAIT: if(recovery_done) begin
            // 无论恢复结果如何均重建事务状态，不沿用旧通道或半个旧读数。
            timer<=0;reading<=0;step<=0;channel<=0;schedule_step<=0;
            high_byte<=0;low_byte<=0;
            if(recovery_error) begin fault<=1;state<=DELAY;end
            // 恢复成功只是允许重新配置 ADC；fault 仍须等新样本成功才清零。
            else begin byte_enable<=1;state<=ISSUE;end
          end
          DELAY: if(timer==RETRY_CYCLES-1) begin
            timer<=0;state<=RECOVER_ISSUE;
          end else timer<=timer+1'b1;
          ISSUE: if(!busy) begin
            // 命令编码由 i2c_byte_master 定义：0=START、1=STOP、2=WRITE、3=READ。
            // 配置事务的 step 0..5：START、地址写、指针 01、配置高字节、
            // 配置低字节、STOP。0x90=(7位地址0x48<<1)|写方向0。
            command_valid<=1;read_nack<=1;command<=2;tx<=0;
            if(!reading) case(step)
              0:command<=0;
              1:tx<=8'h90;
              2:tx<=8'h01;
              // 高字节 C3/D3/E3/F3：OS=1 启动转换，MUX=100..111 选 A0..A3，
              // PGA=001 选 ±4.096V，MODE=1 单次转换。相加仅改变 MUX 位。
              3:tx<=8'hC3+{channel,4'b0000};
              // E3：DR=111 对应 860SPS；比较器传统模式、低有效、非锁存，
              // COMP_QUE=11 禁用比较器；不用 ALERT/RDY 判断转换完成。
              4:tx<=8'hE3;
              default:command<=1;
            endcase
            // 读取事务 step 0..7：START、0x90、指针00、重复START、0x91、
            // 高字节读并 ACK、低字节读并 NACK、STOP。ADS1115 寄存器高字节先传。
            else case(step)
              0:command<=0;
              1:tx<=8'h90;
              2:tx<=8'h00;
              3:command<=0;
              4:tx<=8'h91;
              // ACK=主机拉低第九位，要求继续；NACK=释放第九位，结束本次读取。
              // 最后一个读字节的主动 NACK 是正常结束，不是 byte_error。
              5:begin command<=3;read_nack<=0;end
              6:begin command<=3;read_nack<=1;end
              default:command<=1;
            endcase
            state<=WAIT_BYTE;
          end
          WAIT_BYTE: if(done) begin
            // 底层 WRITE 未获 ACK、线被保持低而超时，或 STOP 未确认均进错误分支；
            // 先释放字节引擎，再等待重试并产生恢复 STOP，不直接接受缓存字节。
            if(byte_error) begin
              // Discard both bytes and the entire conversion on any error.
              // Recovery supplies STOP, then configures a fresh conversion.
              fault<=1;timer<=0;reading<=0;step<=0;channel<=0;schedule_step<=0;
              high_byte<=0;low_byte<=0;byte_enable<=0;state<=DELAY;
            end else if(!reading && step==5) begin
              // 配置 STOP 已结束才开始转换等待；采用固定延时，不读取 OS 就绪位。
              timer<=0;state<=CONVERT;
            end else if(reading && step==7) begin
              // sample_channel 使用当前转换通道；随后 channel 的更新只影响下一次转换。
              sample_valid<=1;sample_channel<=channel;sample_data<={high_byte,low_byte};
              fault<=0;reading<=0;step<=0;state<=ISSUE;
              // 0,1,2,0,1,3: faster pads; sliders remain responsive.
              if(PRESSURE_ONLY) begin
                // 此参数优先于 PRESSURE_PRIORITY，仅按 0,1,0,1... 采压力；
                // A2/A3 的缺席不会在本模块中被补成伪样本。
                // A0/A1 only: the keyboard test keeps its fixed gain and pitch.
                channel<=(channel==0)?2'd1:2'd0;
              end else if(PRESSURE_PRIORITY) begin
                // case 使用更新前的 schedule_step，实际完成序列为
                // 0,1,2,0,1,3,...；两路压力各占 2/6，两个滑条各占 1/6。
                schedule_step<=(schedule_step==5)?0:schedule_step+1'b1;
                case(schedule_step)
                  0,3:channel<=1;
                  1:channel<=2;
                  4:channel<=3;
                  default:channel<=0;
                endcase
              // 2 位通道计数自然回绕，普通模式为 0,1,2,3,...。
              end else channel<=channel+1'b1;
            end else begin
              if(reading && step==5) high_byte<=rx;
              if(reading && step==6) low_byte<=rx;
              step<=step+1'b1;state<=ISSUE;
            end
          end
          CONVERT: if(timer==CONVERT_CYCLES-1) begin
            // 延时到期后重新从读事务 step0 开始；转换时间由参数和实际 clk 决定。
            timer<=0;reading<=1;step<=0;state<=ISSUE;
          end else timer<=timer+1'b1;
          default:begin state<=RECOVER_ISSUE;timer<=0;byte_enable<=0;fault<=1;end
        endcase
      end
    end
endmodule
