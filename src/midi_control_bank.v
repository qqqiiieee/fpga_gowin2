`timescale 1ns/1ps
// TINY stock绝对旋钮/手机控制库，全部在clk域；不含UART协议或音频处理。
// 所有页面固定为K1/CC93=time、K2/CC91=feedback、K3/CC71=mod、K4/CC74=wet。
// 7位CC值按{v,v[6]}扩展到0..255；control_page仅保留接口兼容，不参与状态。
// 所有参数是归一化控制码，后级决定时间/滤波系数；这里不宣称听感等价。
// fx_mode=0旁路、1 Delay、2 Chorus、3 Reverb，复位默认OFF；调旋钮不会自动开FX。
// 要听到效果，必须先用ui_fx_cycle或手机参数3打开模式，再调对应FX参数。
// knob_values始终显示四个FX目标，K1在低8位；不显示尚未接管的物理位置。
module midi_control_bank (
    input wire clk, rst_n,
    input wire cc_valid,
    input wire [6:0] cc_number, cc_value,
    input wire [1:0] control_page,
    input wire ui_fx_cycle,
    input wire [7:0] current_master_volume,
    output reg [7:0] master_volume,
    output reg master_volume_valid,
    output reg [7:0] mix_balance, brightness_base,
    output reg [7:0] attack_ctrl, decay_ctrl, sustain_ctrl, release_ctrl,
    output reg [1:0] fx_mode,
    output reg [7:0] fx_amount, fx_time, fx_feedback, fx_mod,
    output wire [31:0] knob_values,
    // 新接口追加在原端口之后，原命名端口调用可不连接手机接口。
    input wire phone_set_valid,
    input wire [7:0] phone_param, phone_value,
    input wire [7:0] phone_query_param,
    output reg [7:0] phone_query_value
);
    reg [3:0] picked_up, position_seen;
    reg [7:0] last_position [0:3];

    // 音量仲裁保持在外部performance_input_hub：实体滑杆、MIDI CC7和手机
    // 仍共用原来的所有权/抢占路径，本模块不新建一个持续覆盖滑杆的音量源。
    // 手机参数0只发master_volume_valid一拍请求，接到原knob_volume请求入口；
    // CC7仍完全由MIDI解析器和原仲裁器处理，不路由到四个FX旋钮。
    // 原仲裁器仍以滑杆锚点累计移动>=4码回切，1..3码抖动不夺权；数值未变的
    // 重复CC7/手机请求也不反复抢占。是否抑制、Panic及同拍来源优先级仍由
    // 外部决定，本模块不绕开这些规则，收到SET不代表手机已经拿到音量所有权。
    // 外部可因滑杆移动、CC7、抑制或Panic改变最终音量，所以master_volume
    // 只是最近请求，不能当作实际状态。GET 0必须回读current_master_volume，
    // 即使外部尚未接受请求或已换回实体滑杆，也不回显手机的旧请求值。
    assign knob_values = {fx_amount, fx_mod, fx_feedback, fx_time};

    // 这里只负责本控制库拥有的参数；音色、输入模式、页面、状态等由主桥查询。
    // 组合读回实际寄存器/外部仲裁结果，不锁存SET的请求值，也不给未知参数回显。
    always @(*) begin
        case (phone_query_param)
            8'd0:  phone_query_value = current_master_volume;
            8'd3:  phone_query_value = {6'd0, fx_mode};
            8'd4:  phone_query_value = fx_amount;
            8'd5:  phone_query_value = fx_time;
            8'd6:  phone_query_value = fx_feedback;
            8'd7:  phone_query_value = fx_mod;
            8'd8:  phone_query_value = attack_ctrl;
            8'd9:  phone_query_value = decay_ctrl;
            8'd10: phone_query_value = sustain_ctrl;
            8'd11: phone_query_value = release_ctrl;
            default: phone_query_value = 8'd0;
        endcase
    end

    reg knob_known;
    reg [1:0] knob_index;
    always @(*) begin
        knob_known = 1'b1;
        knob_index = 2'd0;
        case (cc_number)
            7'd93: knob_index = 2'd0;
            7'd91: knob_index = 2'd1;
            7'd71: knob_index = 2'd2;
            7'd74: knob_index = 2'd3;
            default: knob_known = 1'b0; // CC7完全交给原路径。
        endcase
    end
    wire [7:0] position = {cc_value, cc_value[6]};
    wire [7:0] target = knob_index==0 ? fx_time :
                        (knob_index==1 ? fx_feedback : (knob_index==2 ? fx_mod : fx_amount));
    wire [7:0] distance = position>target ? position-target : target-position;
    // 扩展7位值会跳过部分8位码（例如128），故允许相差1码，确保所有目标可达。
    // 跨越必须用同一目标下的两次采样；切页面不改变目标，也不清除接管历史。
    // 手机重设目标时在下方清掉该旋钮的picked_up、position_seen和last_position。
    wire crossed = position_seen[knob_index] &&
        ((last_position[knob_index]<=target && position>=target) ||
         (last_position[knob_index]>=target && position<=target));
    wire accept_knob = picked_up[knob_index] || distance<=8'd1 || crossed;
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            picked_up <= 0; position_seen <= 0;
            master_volume <= 8'd180; master_volume_valid <= 0;
            // 中点平衡、非零音量、低基础亮度保留FSR动态开亮的余量。
            // 按当前实时ADSR的Q8.12 live_rate映射选择默认：A32约3.875码/帧，
            // 介于旧长笛1与拨弦8之间，仍立即起音；D96约0.242码/帧接近旧1/4，
            // S192约3/4，R128约0.0605码/帧接近旧1/16。此处只输出控制码。
            mix_balance <= 8'd128; brightness_base <= 8'd64;
            attack_ctrl <= 8'd32; decay_ctrl <= 8'd96;
            sustain_ctrl <= 8'd192; release_ctrl <= 8'd128;
            fx_mode <= 0; fx_amount <= 8'd64;
            fx_time <= 8'd96; fx_feedback <= 8'd80; fx_mod <= 8'd48;
            for (i=0; i<4; i=i+1) last_position[i] <= 0;
        end else begin
            master_volume_valid <= 0;
            if (ui_fx_cycle) fx_mode <= fx_mode + 2'd1;
            if (cc_valid && knob_known) begin
                last_position[knob_index] <= position;
                position_seen[knob_index] <= 1;
                if (accept_knob) begin
                    picked_up[knob_index] <= 1;
                    case (knob_index)
                        0: fx_time <= position;
                        1: fx_feedback <= position;
                        2: fx_mod <= position;
                        3: fx_amount <= position;
                    endcase
                end
            end

            // 主phone_link先校验协议/范围，只对合法SET发单clk脉冲；这里仍只
            // 接受已知可写参数，且必须检查mode<=3，避免8位截断成一个合法模式。
            // SET放在CC/UI之后：同拍只覆盖目标字段，其它旋钮的CC仍可正常更新。
            // FX SET连同同拍CC采样一起丢弃，并清除旧采样/接管；下一条CC才是新
            // 目标下的第一采样。即使SET值与旧值相同，也必须重新软接管，不能拿
            // 改前或同拍的位置制造假跨越。未连接phone_set_valid的旧命名调用
            // 在仿真中为Z，if不会执行；不要把它组合进CC使能导致旧调用丢失CC。
            if (phone_set_valid) begin
                case (phone_param)
                    8'd0: begin
                        master_volume <= phone_value;
                        master_volume_valid <= 1'b1;
                    end
                    8'd3: if (phone_value <= 8'd3) fx_mode <= phone_value[1:0];
                    8'd4: begin
                        fx_amount <= phone_value;
                        picked_up[3] <= 0; position_seen[3] <= 0; last_position[3] <= 0;
                    end
                    8'd5: begin
                        fx_time <= phone_value;
                        picked_up[0] <= 0; position_seen[0] <= 0; last_position[0] <= 0;
                    end
                    8'd6: begin
                        fx_feedback <= phone_value;
                        picked_up[1] <= 0; position_seen[1] <= 0; last_position[1] <= 0;
                    end
                    8'd7: begin
                        fx_mod <= phone_value;
                        picked_up[2] <= 0; position_seen[2] <= 0; last_position[2] <= 0;
                    end
                    8'd8:  attack_ctrl <= phone_value;
                    8'd9:  decay_ctrl <= phone_value;
                    8'd10: sustain_ctrl <= phone_value;
                    8'd11: release_ctrl <= phone_value;
                    default: ;
                endcase
            end
        end
    end
endmodule
