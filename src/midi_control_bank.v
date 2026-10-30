`timescale 1ns/1ps
// V031：K1/CC93=Delay强度、K2/CC91=Chorus强度、K3/CC71=Reverb强度、K4/CC74=总音量。
// 三效果共享一个引擎；接受的强度发生变化才切模式，0强度为干声。
// 各效果保存独立强度(默认64)，非活动效果按自己的目标软接管，不追逐当前湿度。
// 手机SET3恢复所选效果的已存强度；SET4更新当前/最近效果(复位为Delay)。
// 手机SET3清三效果接管历史，SET4清对应历史；两者同拍均优先于效果CC。
// K4跟踪实际音量；滑杆/CC7改变实际值后重新接管，自己的请求回读除外。
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
    input wire phone_set_valid,
    input wire [7:0] phone_param, phone_value,
    input wire [7:0] phone_query_param,
    output reg [7:0] phone_query_value
);
    reg [7:0] effect_amount [0:2];
    reg [1:0] amount_owner;
    reg [3:0] picked_up, position_seen;
    reg [7:0] last_position [0:3];
    reg [7:0] last_actual_volume;
    reg [2:0] volume_ack_window;
    // 请求不是状态。显示/GET0始终读实际仲裁值，K1在最低字节。
    assign knob_values={current_master_volume,effect_amount[2],effect_amount[1],effect_amount[0]};
    always @(*) begin
        case(phone_query_param)
            0:phone_query_value=current_master_volume;
            3:phone_query_value={6'd0,fx_mode};
            4:phone_query_value=fx_amount;
            5:phone_query_value=fx_time;
            6:phone_query_value=fx_feedback;
            7:phone_query_value=fx_mod;
            8:phone_query_value=attack_ctrl;
            9:phone_query_value=decay_ctrl;
            10:phone_query_value=sustain_ctrl;
            11:phone_query_value=release_ctrl;
            default:phone_query_value=0;
        endcase
    end
    reg knob_known;
    reg [1:0] knob_index;
    reg phone_fx_priority,phone_volume_priority;
    always @(*) begin
        knob_known=1;
        case(cc_number)
            93:knob_index=0;91:knob_index=1;71:knob_index=2;74:knob_index=3;
            default:begin knob_index=0;knob_known=0;end
        endcase
        // 显式if让旧命名实例手机输入悬空(Z)时仍能使用MIDI。
        phone_fx_priority=0;phone_volume_priority=0;
        if(phone_set_valid)begin
            if(phone_param==4 || (phone_param==3 && phone_value<=3))phone_fx_priority=1;
            if(phone_param==0)phone_volume_priority=1;
        end
    end
    wire [7:0] position={cc_value,cc_value[6]};
    wire [7:0] target=knob_index==3?current_master_volume:effect_amount[knob_index];
    wire [7:0] distance=position>target?position-target:target-position;
    // bank->hub->实际值回读为两拍；4拍窗口仅识别自己的请求确认。
    // 被拒绝的请求不长期豁免后来滑杆/CC7变化，也不会周期重发。
    wire own_volume_ack=(volume_ack_window!=0 && current_master_volume==master_volume);
    wire external_volume_change=(current_master_volume!=last_actual_volume && !own_volume_ack);
    wire fresh_volume_target=(knob_index==3 && external_volume_change);
    wire crossed=position_seen[knob_index] && !fresh_volume_target &&
        ((last_position[knob_index]<=target && position>=target) ||
         (last_position[knob_index]>=target && position<=target));
    wire accept_knob=distance<=1 || crossed || (picked_up[knob_index] && !fresh_volume_target);
    integer i;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            picked_up<=0;position_seen<=0;amount_owner<=0;
            master_volume<=180;master_volume_valid<=0;
            last_actual_volume<=160;volume_ack_window<=0;
            mix_balance<=128;brightness_base<=64;
            attack_ctrl<=32;decay_ctrl<=96;sustain_ctrl<=192;release_ctrl<=128;
            fx_mode<=0;fx_amount<=64;fx_time<=96;fx_feedback<=80;fx_mod<=48;
            for(i=0;i<3;i=i+1)effect_amount[i]<=64;
            for(i=0;i<4;i=i+1)last_position[i]<=0;
        end else begin
            master_volume_valid<=0;
            last_actual_volume<=current_master_volume;
            if(volume_ack_window!=0)volume_ack_window<=volume_ack_window-1'b1;
            if(external_volume_change)begin
                picked_up[3]<=0;position_seen[3]<=0;last_position[3]<=0;volume_ack_window<=0;
            end
            // 旧接口保留；当前四键top固定ui_fx_cycle=0，不占用菜单键。
            if(ui_fx_cycle)begin
                fx_mode<=fx_mode+2'd1;
                if(fx_mode!=3)begin amount_owner<=fx_mode;fx_amount<=effect_amount[fx_mode];end
                picked_up[2:0]<=0;position_seen[2:0]<=0;
            end
            if(cc_valid && knob_known && !(knob_index==3?phone_volume_priority:phone_fx_priority))begin
                last_position[knob_index]<=position;position_seen[knob_index]<=1;
                if(accept_knob)begin
                    picked_up[knob_index]<=1;
                    if(knob_index!=3)begin
                        // 首次匹配只接管；真正变化才选效果。重复未变值不抢模式。
                        if(position!=target)begin
                            effect_amount[knob_index]<=position;
                            amount_owner<=knob_index;fx_mode<=knob_index+2'd1;fx_amount<=position;
                        end
                    end else if(position!=target &&
                        (!position_seen[3] || fresh_volume_target || position!=last_position[3]))begin
                        // 只发变化事件，沿用hub的抑制/Panic/滑杆累计>=4码/CC7仲裁。
                        master_volume<=position;master_volume_valid<=1;volume_ack_window<=4;
                    end
                end
            end
            if(phone_set_valid)case(phone_param)
                0:begin
                    master_volume<=phone_value;master_volume_valid<=1;volume_ack_window<=4;
                    picked_up[3]<=0;position_seen[3]<=0;last_position[3]<=0;
                end
                3:if(phone_value<=3)begin
                    fx_mode<=phone_value[1:0];
                    if(phone_value!=0)begin
                        amount_owner<=phone_value[1:0]-2'd1;
                        fx_amount<=effect_amount[phone_value[1:0]-2'd1];
                    end
                    // 手机明确选模式包括OFF；同拍效果CC丢弃，旧历史不可制造假跨越。
                    picked_up[2:0]<=0;position_seen[2:0]<=0;
                    for(i=0;i<3;i=i+1)last_position[i]<=0;
                end
                4:begin
                    fx_amount<=phone_value;effect_amount[amount_owner]<=phone_value;
                    picked_up[amount_owner]<=0;position_seen[amount_owner]<=0;last_position[amount_owner]<=0;
                end
                5:fx_time<=phone_value;
                6:fx_feedback<=phone_value;
                7:fx_mod<=phone_value;
                8:attack_ctrl<=phone_value;
                9:decay_ctrl<=phone_value;
                10:sustain_ctrl<=phone_value;
                11:release_ctrl<=phone_value;
                default:;
            endcase
        end
    end
endmodule
