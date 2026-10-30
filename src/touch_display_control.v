// V023 FIXED_FX=1时旋钮固定效果；演奏页S1/S2/S3不再选MAIN/ADSR。
// 曲库仍用S1/S2/S3，其他翻页/音色/效果/验证操作保持；ADSR通过手机编辑。
// 模拟电容键盘专职控制 HDMI：keys[0]..keys[15] 对应消抖后的 S1..S16。
// clk 为源时钟，rst_n 异步低有效，sample_tick 为 93750Hz 时钟使能而非新时钟。
// 普通单键松开确认；所有 *_pulse / song_* / fx_cycle / timbre_set_valid 仅一个 clk。
// S13 为独立安全通道，测试持有期间也立即发 Panic；按住、ghost恢复都不重复。
// page=演奏/曲库/帮助/诊断(0..3)，cursor=菜单0..2，song_id=曲目0..2。
// 演奏页 S1/S2 选择 MAIN/ADSR/FX，S3 确认，S4/S16 返回；S5/S6 前后翻页。
// S7播放暂停，S8重启，S9长笛(ID0)，S10拨弦(ID1)，S11键盘/扫弦，S12效果。
// S14短按切滤波，长按松开切数字静音；默认112500个采样即1.2秒，可参数覆盖。
// 普通状态单S15持续映射0x5000给旧测试控制器，由旧模块计满2秒后取得所有权。
// 测试期间只透传真实S1..S6和S16的电平；其余菜单状态冻结，Panic仍独立有效。
// key_pause 表示触摸/歧义/交接正占用交互，供父层暂停曲目判定，不负责音符隔离。
// 输出 filter_enable 复位1；zero_mode/strum_mode/control_page复位0，均为持续状态。
// 主层在 panic_pulse && test_owned 时注入测试退出键并锁存静音，本模块不复位音频。
// G/V/S one-hot touch UI, source clk domain. sample_tick is an enable (93750Hz).
// All commands commit on a clean release except immediate, single-shot S13 panic.
// S14: short release toggles filter; >=HOLD_SAMPLES toggles digital zero on release.
// S15 maps to the legacy diagnostic entry chord only; that engine owns the 2s timer.
// test_keys is a LEVEL interface to oscillator_test_control, not an event pulse.
// On ownership changes/ghost/chords/key substitution, require a clean all-release.
// control_page: 0 MAIN, 1 ADSR, 2 FX. LIVE S1/S2 selects, S3 confirms.
// This module has no note/event output. Parent must isolate all 16 touch keys
// from the musical input path; key_pause pauses guide evaluation during gestures.
module touch_display_control #(parameter integer HOLD_SAMPLES=112500,parameter integer FIXED_FX=0)(
    input clk,input rst_n,input sample_tick,input [15:0] keys,
    input ghost,input test_owned,
    output reg [1:0] page,cursor,song_id,
    output reg song_start,song_toggle,song_restart,
    output wire key_pause,output reg [15:0] test_keys,
    output reg panic_pulse,output reg strum_mode,
    output reg [1:0] control_page,output reg fx_cycle,
    output reg timbre_set_valid,output reg [3:0] timbre_set_value,
    output reg filter_enable,output reg zero_mode,
    input phone_set_valid,input [7:0] phone_param,phone_value
);
    localparam integer HOLD_LIMIT=HOLD_SAMPLES<1 ? 1 : HOLD_SAMPLES;
    localparam integer HOLD_WIDTH=HOLD_LIMIT<2 ? 1 : $clog2(HOLD_LIMIT+1);
    reg [HOLD_WIDTH-1:0] held_samples;
    reg long_press,wait_release,cancelled,owned_previous;
    reg [15:0] pending;
    reg test_cancelled;
    reg panic_wait_release;
    reg [15:0] test_previous;
    wire single_key=(keys!=0) && ((keys & (keys-16'd1))==0);
    wire clean_release=(keys==0) && !ghost;
    assign key_pause=(keys!=0) || ghost || test_owned || wait_release;

    // 安全 Panic 不经过菜单候选，也不受诊断所有权和所有权交接的清空分支屏蔽。
    // 一次手势最多触发一次；ghost/多键污染后必须先干净全松，避免恢复时伪造边沿。
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin panic_pulse<=0;panic_wait_release<=0;end
        else begin
            panic_pulse<=0;
            if(clean_release)panic_wait_release<=0;
            else if(ghost || !single_key)panic_wait_release<=1;
            else if(keys==16'h1000 && !panic_wait_release)begin
                panic_pulse<=1;panic_wait_release<=1;
            end
        end
    end

    always @* begin
        test_keys=0;
        if(rst_n && !ghost && single_key) begin
            // S16 must reach the old engine during fade-in/out too. UI arming
            // must not prevent diagnostic exit while an entry key is still held.
            if(test_owned) begin
                if(!test_cancelled && (test_previous==0 || keys==test_previous) &&
                   (keys & 16'h803f)!=0)test_keys=keys;
            end else if(!wait_release && !cancelled && !owned_previous && keys==16'h4000 &&
                        (pending==0 || pending==16'h4000))test_keys=16'h5000;
        end
    end

    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin test_cancelled<=0;test_previous<=0;end
        else if(!test_owned || !owned_previous)begin test_cancelled<=0;test_previous<=0;end
        else begin
            test_previous<=keys;
            if(clean_release)test_cancelled<=0;
            else if(ghost || !single_key || (test_previous!=0 && test_previous!=keys))test_cancelled<=1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            page<=0;cursor<=0;song_id<=0;control_page<=FIXED_FX?2:0;
            song_start<=0;song_toggle<=0;song_restart<=0;
            strum_mode<=0;fx_cycle<=0;timbre_set_valid<=0;timbre_set_value<=0;
            filter_enable<=1;zero_mode<=0;pending<=0;
            held_samples<=0;long_press<=0;wait_release<=1;cancelled<=0;owned_previous<=0;
        end else begin
            song_start<=0;song_toggle<=0;song_restart<=0;
            fx_cycle<=0;timbre_set_valid<=0;
            owned_previous<=test_owned;
            // 手机仅改变UI参数；不会用触摸键伪造音符。绝对SET优先于同拍抬手。
            if(phone_set_valid && (phone_param==2 || phone_param==12 || phone_param==13 || phone_param==14))begin
                if(phone_param==2)strum_mode<=phone_value[0];
                if(phone_param==12)begin page<=phone_value[1:0];cursor<=0;end
                if(phone_param==13)filter_enable<=phone_value[0];
                if(phone_param==14)zero_mode<=phone_value[0];
                pending<=0;held_samples<=0;long_press<=0;cancelled<=0;wait_release<=1;
            end else if(test_owned || owned_previous!=test_owned) begin
                pending<=0;held_samples<=0;long_press<=0;cancelled<=0;wait_release<=1;
            end else if(wait_release) begin
                if(clean_release)wait_release<=0;
            end else if(clean_release) begin
                if(!cancelled) begin
                    case(pending)
                        16'h0001: if(!FIXED_FX || page!=0)cursor<=cursor==0 ? 2'd2 : cursor-2'd1;
                        16'h0002: if(!FIXED_FX || page!=0)cursor<=cursor==2 ? 2'd0 : cursor+2'd1;
                        16'h0004: begin
                            if(page==1)begin song_id<=cursor;song_start<=1;page<=0;cursor<=0;end
                            else if(page==0 && !FIXED_FX)control_page<=cursor;
                        end
                        16'h0008,16'h8000: begin
                            if(!FIXED_FX && control_page!=0)control_page<=0;
                            else begin page<=0;cursor<=0;end
                        end
                        16'h0010: begin page<=page-2'd1;cursor<=page==2 ? song_id : 2'd0;end
                        16'h0020: begin page<=page+2'd1;cursor<=page==0 ? song_id : 2'd0;end
                        16'h0040: song_toggle<=1;
                        16'h0080: song_restart<=1;
                        16'h0100: begin timbre_set_valid<=1;timbre_set_value<=0;end
                        16'h0200: begin timbre_set_valid<=1;timbre_set_value<=1;end
                        16'h0400: strum_mode<=!strum_mode;
                        16'h0800: fx_cycle<=1;
                        16'h2000: begin
                            if(long_press)zero_mode<=!zero_mode;
                            else filter_enable<=!filter_enable;
                        end
                        default: begin end // S13 already fired; S15 belongs to test engine.
                    endcase
                end
                pending<=0;held_samples<=0;long_press<=0;cancelled<=0;
            end else if(ghost || !single_key || (pending!=0 && pending!=keys)) begin
                cancelled<=1;held_samples<=0;long_press<=0;
            end else if(!cancelled && pending==0) begin
                pending<=keys;
                if(keys==16'h2000 && sample_tick)begin
                    if(HOLD_LIMIT==1)long_press<=1;
                    else held_samples<=1;
                end
            end else if(!cancelled && pending==16'h2000 && sample_tick && !long_press) begin
                if(held_samples>=HOLD_LIMIT-1)long_press<=1;
                else held_samples<=held_samples+1'b1;
            end
        end
    end
endmodule
