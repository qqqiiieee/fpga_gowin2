// 模块职责：完成一条 I2C START/STOP/字节写/字节读命令，不管理器件地址或寄存器。
// 端口：clk 为系统时钟，rst_n 异步低有效；cmd_valid 在 busy=0 时采纳，
// cmd 为 0=START、1=STOP、2=WRITE、3=READ；tx_data 为待发的 8 位字节。
// read_nack 仅对 READ 生效：0 在第九位回 ACK，1 回 NACK 结束读取。
// busy 表示命令进行中；done 是完成单拍，必须同时查看 error；rx_data 在
// READ 成功结束时更新并保持，其他命令不刷新它。scl/sda 为开漏双向总线。
// rst_n 低时立即释放两根线，清忙/完成/错误；闲置不自动产生 STOP，
// 成功完成字节后 SCL 保持低，由下一条命令继续事务。超时会释放两根线。
// QUARTER_CYCLES/TIMEOUT_CYCLES 单位为 clk 周期。默认 clk=27MHz，
// 68 周期约 2.52us，四相位位周期约 10.07us；270000 周期为 10ms。
// 参数须为正：QUARTER_CYCLES-1 要能由16位 divider 计到，
// TIMEOUT_CYCLES-1 要能由24位 watchdog 计到；这里没有参数自动限幅。
// 无外部 clock enable：内部相位使能推进状态，超时和输入同步仍每 clk 运行。
// error 保持到下一命令接收时清零；不能脱离 done 把旧 error 当成新事件。
// 状态机按 START、STOP、写8位+从机ACK、读8位+主机ACK/NACK 分组；
// SCL 释放后等待实际同步电平为高，支持从机时钟延展，等待计入命令超时。
// 本模块没有多主仲裁逻辑；上层须保证恢复引擎与本引擎的独占总线所有权。
// Open-drain byte engine, ~100kHz at 27MHz. Supports clock stretching.
module v015_i2c_byte_master #(
    parameter QUARTER_CYCLES=68, parameter TIMEOUT_CYCLES=270000
)(input clk,input rst_n,input cmd_valid,input [1:0] cmd,
  input [7:0] tx_data,input read_nack,output reg busy,output reg done,
  output reg error,output reg [7:0] rx_data,inout scl,inout sda);
    localparam START=0,STOP=1,WRITE=2,READ=3;
    localparam IDLE=0,START_WAIT=1,START_HOLD=2,STOP_LOW=3,STOP_HIGH=4,STOP_END=5,
      W_LOW=6,W_RISE=7,W_HIGH=8,W_FALL=9,WA_LOW=10,WA_RISE=11,WA_HIGH=12,WA_FALL=13,
      R_LOW=14,R_RISE=15,R_HIGH=16,R_FALL=17,RA_LOW=18,RA_RISE=19,RA_HIGH=20,RA_FALL=21;
    reg [4:0] state;
    reg scl_low,sda_low;
    reg [15:0] divider;
    reg [23:0] watchdog;
    reg [2:0] bit_no;
    reg [7:0] shift;
    reg nack;
    reg scl_meta,scl_sync,sda_meta,sda_sync;
    // *_low=1 只拉低，=0 输出高阻 Z，靠外部上拉得到高；绝不可改为驱动 1。
    // 释放 SCL 不等于物理 SCL 已高，必须依据 scl_sync 判断延展结束。
    assign scl=scl_low?1'b0:1'bz;
    assign sda=sda_low?1'b0:1'bz;
    // 两级寄存器同步外部线，后续状态机只读第二级，降低异步输入亚稳态传播。
    always @(posedge clk or negedge rst_n) begin
      if(!rst_n) begin scl_meta<=1;scl_sync<=1;sda_meta<=1;sda_sync<=1;end
      else begin scl_meta<=scl;scl_sync<=scl_meta;sda_meta<=sda;sda_sync<=sda_meta;end
    end
    // 命令执行器：divider 每 QUARTER_CYCLES 个周期允许一次相位推进；
    // watchdog 在 busy 全程累计，等 ACK/延展/STOP 时也不暂停或重新计时。
    always @(posedge clk or negedge rst_n) begin
      if(!rst_n) begin
        state<=IDLE;scl_low<=0;sda_low<=0;divider<=0;watchdog<=0;
        busy<=0;done<=0;error<=0;rx_data<=0;shift<=0;bit_no<=7;nack<=1;
      end else begin
        done<=0;
        if(!busy) begin
          divider<=0;watchdog<=0;
          if(cmd_valid) begin
            // 此时锁存发送字节与读应答选择，busy 期间的新 cmd_valid 不排队。
            busy<=1;error<=0;shift<=tx_data;bit_no<=7;nack<=read_nack;
            case(cmd)
              START: begin scl_low<=0;sda_low<=0;state<=START_WAIT;end
              STOP: begin scl_low<=1;sda_low<=1;state<=STOP_LOW;end
              WRITE: begin scl_low<=1;sda_low<=!tx_data[7];state<=W_LOW;end
              default: begin scl_low<=1;sda_low<=0;shift<=0;state<=R_LOW;end
            endcase
          end
        end else if(watchdog==TIMEOUT_CYCLES-1) begin
          // 全命令超时：done=1 与 error=1 同拍，释放总线；恢复/重试由上层处理。
          scl_low<=0;sda_low<=0;busy<=0;done<=1;error<=1;state<=IDLE;
        end else begin
          watchdog<=watchdog+1'b1;
          if(divider==QUARTER_CYCLES-1) begin
            divider<=0;
            case(state)
              // START/重复START：先释放两线并等它们实际都高，再在 SCL 高时拉低 SDA。
              // START_HOLD 随后拉低 SCL，给地址/下一数据位留出低电平阶段。
              START_WAIT: if(scl_sync && sda_sync) begin sda_low<=1;state<=START_HOLD;end
              START_HOLD: begin scl_low<=1;busy<=0;done<=1;state<=IDLE;end
              // STOP：先两线低，释放 SCL 等实际高，再释放 SDA，构成高时上升沿。
              STOP_LOW: begin scl_low<=0;state<=STOP_HIGH;end
              STOP_HIGH: if(scl_sync) begin sda_low<=0;state<=STOP_END;end
              // A held-low SDA must not turn a failed final STOP into a sample.
              // 必须观察两线都高才完成 STOP；SDA 被从机拉住则一直等到 watchdog 超时。
              STOP_END: if(scl_sync && sda_sync) begin busy<=0;done<=1;state<=IDLE;end
              // 写字节按 bit_no=7..0、MSB 先发；仅在 SCL 低时更新 SDA 数据。
              // W_HIGH 只等 SCL 实际高，不比较 SDA 做仲裁。
              W_LOW: state<=W_RISE;
              W_RISE: begin scl_low<=0;state<=W_HIGH;end
              W_HIGH: if(scl_sync) state<=W_FALL;
              W_FALL: begin
                scl_low<=1;
                if(bit_no==0) begin sda_low<=0;state<=WA_LOW;end
                else begin bit_no<=bit_no-1'b1;sda_low<=!shift[bit_no-1'b1];state<=W_LOW;end
              end
              // 发完 8 位立即释放 SDA，第九个 SCL 高阶段读取从机应答。
              // SDA=0 是 ACK/error=0；SDA=1 是 NACK/error=1，仍正常产生 done。
              WA_LOW: state<=WA_RISE;
              WA_RISE: begin scl_low<=0;state<=WA_HIGH;end
              WA_HIGH: if(scl_sync) begin error<=sda_sync;state<=WA_FALL;end
              WA_FALL: begin scl_low<=1;sda_low<=0;busy<=0;done<=1;state<=IDLE;end
              // 读阶段全程释放 SDA，逐位在确认 SCL 高后采样，填入 shift[7..0]。
              R_LOW: state<=R_RISE;
              R_RISE: begin scl_low<=0;state<=R_HIGH;end
              R_HIGH: if(scl_sync) begin shift[bit_no]<=sda_sync;state<=R_FALL;end
              R_FALL: begin
                scl_low<=1;
                // 最后一位之后主机提供第九位：nack=0 拉低回 ACK，nack=1 高阻回 NACK。
                if(bit_no==0) begin sda_low<=!nack;state<=RA_LOW;end
                else begin bit_no<=bit_no-1'b1;state<=R_LOW;end
              end
              RA_LOW: state<=RA_RISE;
              RA_RISE: begin scl_low<=0;state<=RA_HIGH;end
              RA_HIGH: if(scl_sync) state<=RA_FALL;
              // READ 的主动 NACK 不置 error；只在第九位下降阶段提交整字节。
              RA_FALL: begin scl_low<=1;sda_low<=0;rx_data<=shift;busy<=0;done<=1;state<=IDLE;end
              default: begin scl_low<=0;sda_low<=0;busy<=0;done<=1;error<=1;state<=IDLE;end
            endcase
          end else divider<=divider+1'b1;
        end
      end
    end
endmodule

// 模块职责：释放 SDA，产生九个可被实际观察到的 SCL 脉冲，再生成并验证 STOP，
// 尝试解除从机停在半个字节/应答阶段的总线占用；不会复位或重新配置外部器件。
// 端口：clk 为系统时钟，rst_n 为异步低有效复位；start 在 busy=0 时采纳。
// busy 为整次恢复占用，done 为结束单拍，error=1 表示超时/非法状态，
// error=0 表示九脉冲和 STOP 后两线持续为高。scl/sda 为需外部上拉的开漏线。
// rst_n 低和闲置时释放两线；上层在本模块 busy 期间须令字节引擎复位，
// 保证只有本模块控制总线，不得在另一个引擎仍拉低 SCL 时同时恢复。
// 参数以 clk 周期计：默认 27MHz、QUARTER_CYCLES=68，半周期=136，
// 低/高各约 5.04us；TIMEOUT_CYCLES=270000 是整次恢复共用的 10ms 上限。
// QUARTER_CYCLES/TIMEOUT_CYCLES 须为正，HALF_CYCLES 和超时须可由32位计数器计到；
// 参数没有自动钳位。无外部采样使能，每 clk 检查实际线电平和总超时。
// start 在 busy 期间不排队；error 保持本次结果到下一 start，done 才标记新结果。
// 状态机：CLOCK_LOW/RISE/HIGH 循环九次 -> STOP_LOW/DATA/RISE/HIGH/VERIFY。
// 从机延展或永久拉低均计入总超时；释放线不等于已经变高，须看同步输入。
// Nine physical open-drain SCL clocks followed by STOP. The byte engine must
// be held in reset while this module owns the bus. TIMEOUT_CYCLES bounds the
// entire attempt, including slave stretching and a permanently low SDA/SCL.
module v015_i2c_bus_recovery #(
    parameter QUARTER_CYCLES=68, parameter TIMEOUT_CYCLES=270000
)(input clk,input rst_n,input start,output reg busy,output reg done,
  output reg error,inout scl,inout sda);
    localparam IDLE=0,CLOCK_LOW=1,CLOCK_RISE=2,CLOCK_HIGH=3,
      STOP_LOW=4,STOP_DATA=5,STOP_RISE=6,STOP_HIGH=7,STOP_VERIFY=8;
    localparam HALF_CYCLES=2*QUARTER_CYCLES;
    reg [3:0] state;
    reg [3:0] pulse_count;
    reg [31:0] timer,watchdog;
    reg scl_low,sda_low;
    reg scl_meta,scl_sync,sda_meta,sda_sync;
    // 开漏只允许 0 或 Z；高电平由上拉提供，不能强推 1 去对抗从机拉低。
    assign scl=scl_low?1'b0:1'bz;
    assign sda=sda_low?1'b0:1'bz;
    // 外部 SCL/SDA 各用两级寄存器同步；以实际线电平验证脉冲与 STOP。
    always @(posedge clk or negedge rst_n) begin
      if(!rst_n) begin scl_meta<=1;scl_sync<=1;sda_meta<=1;sda_sync<=1;end
      else begin scl_meta<=scl;scl_sync<=scl_meta;sda_meta<=sda;sda_sync<=sda_meta;end
    end
    // timer 计单个低/高/验证阶段，watchdog 计整个恢复过程，后者不中途清零。
    always @(posedge clk or negedge rst_n) begin
      if(!rst_n) begin
        state<=IDLE;pulse_count<=0;timer<=0;watchdog<=0;
        scl_low<=0;sda_low<=0;busy<=0;done<=0;error<=0;
      end else begin
        done<=0;
        if(!busy) begin
          scl_low<=0;sda_low<=0;timer<=0;watchdog<=0;
          if(start) begin
            // pulse_count 从 0 计已到达的脉冲编号，SDA 在九脉冲期间保持释放。
            busy<=1;error<=0;pulse_count<=0;scl_low<=1;state<=CLOCK_LOW;
          end
        end else if(watchdog==TIMEOUT_CYCLES-1) begin
          // 超时立即释放两线并回报失败；这里只退出，下一次尝试由上层决定。
          scl_low<=0;sda_low<=0;busy<=0;done<=1;error<=1;state<=IDLE;
        end else begin
          watchdog<=watchdog+1'b1;
          case(state)
            CLOCK_LOW: if(timer==HALF_CYCLES-1) begin
              timer<=0;scl_low<=0;state<=CLOCK_RISE;
            end else timer<=timer+1'b1;
            CLOCK_RISE: if(scl_sync) begin timer<=0;state<=CLOCK_HIGH;end
            // 高电平计时途中若 SCL 又被拉低，重新等待上升并重计高电平时间；
            // 不能只计内部状态变化就把被延展的时钟当成有效恢复脉冲。
            CLOCK_HIGH: if(!scl_sync) begin timer<=0;state<=CLOCK_RISE;end
            else if(timer==HALF_CYCLES-1) begin
              timer<=0;scl_low<=1;
              // 编号 0..8 共九次完整高阶段；即使 SDA 提前释放也完成九次，再作 STOP。
              if(pulse_count==8) state<=STOP_LOW;
              else begin pulse_count<=pulse_count+1'b1;state<=CLOCK_LOW;end
            end else timer<=timer+1'b1;
            // 第九脉冲后先保持 SCL 低，再拉低 SDA；避免 SCL 高时产生额外 START。
            STOP_LOW: if(timer==HALF_CYCLES-1) begin
              timer<=0;sda_low<=1;state<=STOP_DATA;
            end else timer<=timer+1'b1;
            // SDA 低电平建立一个半周期后释放 SCL，并等待其物理高电平。
            STOP_DATA: if(timer==HALF_CYCLES-1) begin
              timer<=0;scl_low<=0;state<=STOP_RISE;
            end else timer<=timer+1'b1;
            STOP_RISE: if(scl_sync) begin timer<=0;state<=STOP_HIGH;end
            STOP_HIGH: if(!scl_sync) begin timer<=0;state<=STOP_RISE;end
            else if(timer==HALF_CYCLES-1) begin
              // SCL 持续高满一个半周期后释放 SDA，产生 STOP 的低到高变化。
              timer<=0;sda_low<=0;state<=STOP_VERIFY;
            end else timer<=timer+1'b1;
            // 两线都高且持续 HALF_CYCLES 才成功；任一低则重新计验证时间，
            // watchdog 仍继续，防止 SDA 一直低却被误判为恢复成功。
            STOP_VERIFY: if(!scl_sync || !sda_sync) timer<=0;
            else if(timer==HALF_CYCLES-1) begin
              busy<=0;done<=1;error<=0;state<=IDLE;
            end else timer<=timer+1'b1;
            default: begin
              scl_low<=0;sda_low<=0;busy<=0;done<=1;error<=1;state<=IDLE;
            end
          endcase
        end
      end
    end
endmodule

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
module v015_ads1115_reader #(
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
    v015_i2c_bus_recovery #(.QUARTER_CYCLES(I2C_QUARTER),
      .TIMEOUT_CYCLES(BYTE_TIMEOUT_CYCLES)) recovery(
      .clk(clk),.rst_n(rst_n),.start(recovery_start),.busy(recovery_busy),
      .done(recovery_done),.error(recovery_error),.scl(scl),.sda(sda));
    v015_i2c_byte_master #(.QUARTER_CYCLES(I2C_QUARTER),
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
            // 命令编码由 v015_i2c_byte_master 定义：0=START、1=STOP、2=WRITE、3=READ。
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
