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
module i2c_bus_recovery #(
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
