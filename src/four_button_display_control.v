// V025 四个独立常开按键，共用 GND；keys_n[0..3] 对应面板 1..4。
// 外部端口使用 3.3V 上拉，按下为0，不需要给薄膜按键接 VCC。
// 两级同步后逐键消抖，默认540000个27MHz时钟=20ms。
// 仅在完整按下/松开后触发一次；长按不连发，多键或换键手势取消。
// 上电按住、测试模式退出均须稳定全松后才重新接收，避免误动作。
// 1短按切页，长按切音色；2短按开始/暂停，长按轮换演奏模式。
// 3短按重播、长按进入振荡器验证；4选下一曲并等待开始。
// 验证期间：1短按轮换路数、2短按启停逐路检查、3短/长按退出、4短按全32路。
// 验证期间忽略1/2/4长按，避免一次手势误作重复短按；3长按不重复退出。
// 长按默认0.8秒，所有命令仍只在消抖松手后输出一个clk，不直接产生音符。
// test_owned的任一边沿都丢弃当前手势，稳定全松后才能在新所有者下操作。
module four_button_display_control #(parameter DEBOUNCE_CYCLES=540000,
    parameter LONG_PRESS_CYCLES=21600000,parameter CUSTOM_SONG_ENABLE=0,parameter GUIDE_MODES_ENABLE=0)(
    input clk,input rst_n,input [3:0] keys_n,
    input guide_done,input test_owned,
    input custom_song_available,input phone_song_command_valid,input [1:0] phone_song_command,
    output reg [1:0] page,song_id,output [1:0] cursor,
    output reg song_start,song_toggle,song_restart,
    output key_pause,output [3:0] buttons_down,
    input phone_set_valid,input [7:0] phone_param,phone_value,
    output reg timbre_cycle,mode_cycle,
    output reg test_toggle,test_count_cycle,test_sweep_toggle,test_full,
    input [1:0] phone_song_id,input phone_guide_mode_valid,input guide_stop,
    output reg guide_mode_cycle
);
    localparam integer LIMIT=DEBOUNCE_CYCLES<1?1:DEBOUNCE_CYCLES;
    localparam integer WIDTH=LIMIT<2?1:$clog2(LIMIT+1);
    localparam integer ARM_LIMIT=LIMIT+2;
    localparam integer ARM_WIDTH=$clog2(ARM_LIMIT+1);
    localparam integer HOLD_LIMIT=LONG_PRESS_CYCLES<1?1:LONG_PRESS_CYCLES;
    localparam integer HOLD_WIDTH=HOLD_LIMIT<2?1:$clog2(HOLD_LIMIT+1);
    reg [3:0] key_meta,key_sync,stable_down;
    reg [WIDTH-1:0] debounce_count [0:3];
    reg [ARM_WIDTH-1:0] release_guard;
    reg armed,started,cancelled,previous_test_owned;
    reg [3:0] pending;
    // 单个饱和计数器服务整个单键手势；多键取消后必须全松，不能降为短按。
    reg [HOLD_WIDTH-1:0] hold_count;
    wire [3:0] raw_down=~key_sync;
    wire single_key=(stable_down!=0) && ((stable_down & (stable_down-4'd1))==0);
    wire ownership_changed=(test_owned!=previous_test_owned);
    assign buttons_down=stable_down;
    assign cursor=song_id;
    // 选曲后等待开始，控制键按住时暂停教学；不暂停MIDI声音或PCM输出。
    assign key_pause=!started || !armed || (stable_down!=0) || test_owned;

    always @(posedge clk or negedge rst_n)
        if(!rst_n)begin key_meta<=4'hf;key_sync<=4'hf;end
        else begin key_meta<=keys_n;key_sync<=key_meta;end

    genvar k;
    generate for(k=0;k<4;k=k+1)begin:debounce
        always @(posedge clk or negedge rst_n)
            if(!rst_n)begin stable_down[k]<=0;debounce_count[k]<=0;end
            else if(raw_down[k]==stable_down[k])debounce_count[k]<=0;
            else if(debounce_count[k]>=LIMIT-1)begin
                stable_down[k]<=raw_down[k];debounce_count[k]<=0;
            end else debounce_count[k]<=debounce_count[k]+1'b1;
    end endgenerate

    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            page<=0;song_id<=0;started<=0;armed<=0;release_guard<=0;
            pending<=0;cancelled<=0;
            song_start<=0;song_toggle<=0;song_restart<=0;
            hold_count<=0;timbre_cycle<=0;mode_cycle<=0;guide_mode_cycle<=0;
            previous_test_owned<=0;
            test_toggle<=0;test_count_cycle<=0;test_sweep_toggle<=0;test_full<=0;
        end else begin
            song_start<=0;song_toggle<=0;song_restart<=0;
            timbre_cycle<=0;mode_cycle<=0;guide_mode_cycle<=0;
            test_toggle<=0;test_count_cycle<=0;test_sweep_toggle<=0;test_full<=0;
            previous_test_owned<=test_owned;
            // V028: page/song have exactly one owner. Absolute phone UI SETs
            // outrank a same-cycle key release, even during test ownership.
            // Cancel the entire pending gesture and require a stable all-up
            // interval; a held key must not undo the phone setting on release.
            // GET and non-UI SETs do not consume a valid four-button gesture.
            if(GUIDE_MODES_ENABLE && guide_stop)begin
                // Panic must not be followed by an automatic demo NoteOn.
                started<=0;song_restart<=1;armed<=0;release_guard<=0;
                pending<=0;cancelled<=0;hold_count<=0;
            end else if(CUSTOM_SONG_ENABLE && (GUIDE_MODES_ENABLE ? (phone_song_id!=3 || custom_song_available) : custom_song_available) && phone_song_command_valid && !test_owned)begin
                // A committed upload selects slot4 and waits for an explicit
                // start; phone start/toggle/restart use the same panel owner.
                song_id<=GUIDE_MODES_ENABLE?phone_song_id:2'd3;page<=0;armed<=0;release_guard<=0;pending<=0;cancelled<=0;hold_count<=0;
                case(phone_song_command)
                    0:begin started<=0;song_restart<=1;end
                    1:begin started<=1;song_start<=1;end
                    2:begin
                        if(!started || guide_done || song_id!=(GUIDE_MODES_ENABLE?phone_song_id:2'd3))begin started<=1;song_start<=1;end
                        else song_toggle<=1;
                    end
                    3:begin started<=1;song_restart<=1;end
                endcase
            end else if(GUIDE_MODES_ENABLE && phone_guide_mode_valid && !test_owned)begin
                // A mode change resets count-in, preserving explicit start/wait.
                song_restart<=1;armed<=0;release_guard<=0;pending<=0;
                cancelled<=0;hold_count<=0;
            end else if(phone_set_valid && (phone_param==1 || phone_param==2 || phone_param==12 ||
                                   phone_param==13 || phone_param==14))begin
                if(phone_param==12)page<=phone_value[1:0];
                armed<=0;release_guard<=0;pending<=0;cancelled<=0;
                hold_count<=0;
            end else if(ownership_changed)begin
                // 仅边沿取消；持续owned时四键归诊断UI，而不是永久屏蔽。
                armed<=0;release_guard<=0;pending<=0;cancelled<=0;
                hold_count<=0;
            end else if(!armed)begin
                pending<=0;cancelled<=0;hold_count<=0;
                // 额外两个时钟覆盖同步流水线，上电按住不能被误认为全松。
                if(key_sync==4'hf && stable_down==0)begin
                    if(release_guard>=ARM_LIMIT-1)begin armed<=1;release_guard<=0;end
                    else release_guard<=release_guard+1'b1;
                end else release_guard<=0;
            end else if(stable_down==0)begin
                if(!cancelled && test_owned)begin
                    // 不改page/song/started，也不泄漏演奏音色或模式命令。
                    // 退出在任何测试阶段都能请求；其它控制由测试状态机
                    // 再检查ACTIVE及controls_armed，不在面板中排队。
                    case(pending)
                        4'b0001:if(hold_count<HOLD_LIMIT)test_count_cycle<=1;
                        4'b0010:if(hold_count<HOLD_LIMIT)test_sweep_toggle<=1;
                        4'b0100:test_toggle<=1;
                        4'b1000:if(hold_count<HOLD_LIMIT)test_full<=1;
                        default:begin end
                    endcase
                end else if(!cancelled)case(pending)
                    4'b0001:if(hold_count>=HOLD_LIMIT)timbre_cycle<=1;
                            else page<=page+2'd1;
                    4'b0010:begin
                        if(hold_count>=HOLD_LIMIT)mode_cycle<=1;
                        else begin
                            page<=0;
                            if(!started || guide_done)begin song_start<=1;started<=1;end
                            else song_toggle<=1;
                        end
                    end
                    4'b0100:begin
                        if(hold_count>=HOLD_LIMIT)test_toggle<=1;
                        else begin page<=0;song_restart<=1;started<=1;end
                    end
                    4'b1000:begin
                        if(GUIDE_MODES_ENABLE && hold_count>=HOLD_LIMIT)begin
                            guide_mode_cycle<=1;song_restart<=1;
                        end else begin
                            song_id<=song_id==((CUSTOM_SONG_ENABLE && custom_song_available)?3:2)?2'd0:song_id+2'd1;
                            page<=1;started<=0;
                        end
                    end
                    default:begin end
                endcase
                pending<=0;cancelled<=0;hold_count<=0;
            end else if(!single_key || (pending!=0 && pending!=stable_down))begin
                cancelled<=1;
            end else if(pending==0 && !cancelled)begin
                pending<=stable_down;hold_count<=1;
            end else if(!cancelled && hold_count<HOLD_LIMIT)hold_count<=hold_count+1'b1;
        end
    end
endmodule
