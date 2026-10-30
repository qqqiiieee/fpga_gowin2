// V025 四个独立常开按键，共用 GND；keys_n[0..3] 对应面板 1..4。
// 外部端口使用 3.3V 上拉，按下为0，不需要给薄膜按键接 VCC。
// 两级同步后逐键消抖，默认540000个27MHz时钟=20ms。
// 仅在完整按下/松开后触发一次；长按不连发，多键或换键手势取消。
// 上电按住、测试模式退出均须稳定全松后才重新接收，避免误动作。
// 1短按切页，长按切音色；2短按开始/暂停，长按轮换演奏模式。
// 3重播；4选下一曲并等待开始；长按默认0.8秒，仍在松手后执行。
// 所有输出均为 clk 域；song_* 是单周期事件，仅控制教学，不产生音符。
module four_button_display_control #(parameter DEBOUNCE_CYCLES=540000,
    parameter LONG_PRESS_CYCLES=21600000)(
    input clk,input rst_n,input [3:0] keys_n,
    input guide_done,input test_owned,
    output reg [1:0] page,song_id,output [1:0] cursor,
    output reg song_start,song_toggle,song_restart,
    output key_pause,output [3:0] buttons_down,
    input phone_set_valid,input [7:0] phone_param,phone_value,
    output reg timbre_cycle,mode_cycle
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
    reg armed,started,cancelled;
    reg [3:0] pending;
    // 单个饱和计数器服务整个单键手势；多键取消后必须全松，不能降为短按。
    reg [HOLD_WIDTH-1:0] hold_count;
    wire [3:0] raw_down=~key_sync;
    wire single_key=(stable_down!=0) && ((stable_down & (stable_down-4'd1))==0);
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
            hold_count<=0;timbre_cycle<=0;mode_cycle<=0;
        end else begin
            song_start<=0;song_toggle<=0;song_restart<=0;
            timbre_cycle<=0;mode_cycle<=0;
            // V028: page/song have exactly one owner. Absolute phone UI SETs
            // outrank a same-cycle key release, even during test ownership.
            // Cancel the entire pending gesture and require a stable all-up
            // interval; a held key must not undo the phone setting on release.
            // GET and non-UI SETs do not consume a valid four-button gesture.
            if(phone_set_valid && (phone_param==1 || phone_param==2 || phone_param==12 ||
                                   phone_param==13 || phone_param==14))begin
                if(phone_param==12)page<=phone_value[1:0];
                armed<=0;release_guard<=0;pending<=0;cancelled<=0;
                hold_count<=0;
            end else if(test_owned)begin
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
                if(!cancelled)case(pending)
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
                    4'b0100:begin page<=0;song_restart<=1;started<=1;end
                    4'b1000:begin
                        song_id<=song_id==2?2'd0:song_id+2'd1;
                        page<=1;started<=0;
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
