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
module i2c_byte_master #(
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
