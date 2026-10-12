// 模块职责：扫描 4x4 无源键盘，逐键消抖、抑制矩形鬼键，再串行输出按下/松开事件；
// 可用 virtual_keys 替换扫描数据；最后四键支持历史分组选择或双键循环选择。
// 端口：clk 为系统时钟，rst_n 为异步低有效复位；rows 为行驱动，cols 为
// 低有效列输入且须上拉。选中行仅驱动 0，其余为 Z，绝不驱动高电平。
// virtual_enable=1 时按行采样 virtual_keys（位1为按下），仍沿用扫描/消抖/ghost。
// 位编号为 row*4+col，即 bit0..15 对应逻辑 S1..S16，不在本模块定义板上引脚。
// velocity 为外部提供的 8 位力度控制量，事件时复制为 vel_out；note 为表内
// 7 位音符编号（采用 MIDI 编号习惯），不含频率单位。note_on/note_off 为单拍，
// note/vel_out/timbre_out 仅应在事件脉冲时使用；key_state 为消抖后按键状态。
// ghost_active 为原始扫描矩形歧义的组合指示；selected_timbre 为当前0..15选择。
// ROW_CYCLES 单位为 clk 周期；默认 27MHz、6750周期/行=0.25ms，四行=1ms。
// DEBOUNCE_FRAMES 为连续不同于已确认状态的完整帧数，默认4帧，约4ms。
// 各状态寄存器异步低复位，扫描从第0行开始；复位时第0行仍按组合逻辑拉低，
// 不是四行全部高阻。状态流程为扫描帧 -> 消抖 -> 逐拍发送未报告的变化。
// PERFORMANCE_MODE=0：全部16键发音且音色编号等于键号；=1：S1..S12发音，
// 最高四键作为控制键，不发音；选择方式还取决于 TWO_BUTTON_SELECT。
// 兼容分组模式中 SELECT_ON_RELEASE=1 时单个选择键须松开才确认；
// =0 时在消抖后的按下边沿确认。TWO_BUTTON_SELECT=1 时强制单键松开确认：
// S13 前一个、S14 后一个，0..15循环；S15/S16留给菜单，不切音色。
// PERFORMANCE_MODE/SELECT_ON_RELEASE/TWO_BUTTON_SELECT 默认均为0，按布尔选项使用。
// TWO_BUTTON_SELECT 默认0只为兼容历史四组/四变体选择；生产 input_hub 显式
// 设 PERFORMANCE_MODE=1、SELECT_ON_RELEASE=1、TWO_BUTTON_SELECT=1、消抖3帧。
// ROW_CYCLES 须为1..65536；DEBOUNCE_FRAMES 须为1..256以匹配16/8位计数器。
// frame_tick 是内部完整扫描使能，不是新时钟；选择/事件序列按每个 clk 处理。
// 4x4 passive matrix. Rows drive low or high impedance; columns need pull-ups.
// One full scan = 1ms at 27MHz.
// 生产键位：S1..S12演奏；S13/S14前后音色；S15/S16供上层菜单/组合键识别。
// suppress_select仅冻结音色选择，不冻结扫描、消抖和key_state。
module matrix_keypad #(
    parameter ROW_CYCLES = 6750,
    parameter DEBOUNCE_FRAMES = 4,
    parameter PERFORMANCE_MODE = 0,
    parameter SELECT_ON_RELEASE = 0,
    parameter TWO_BUTTON_SELECT = 0
)(
    input suppress_select,
    input clk,
    input rst_n,
    output [3:0] rows,
    input [3:0] cols,
    input virtual_enable,
    input [15:0] virtual_keys,
    input [7:0] velocity,
    output reg note_on,
    output reg note_off,
    output reg [6:0] note,
    output reg [7:0] vel_out,
    output reg [3:0] timbre_out,
    output reg [15:0] key_state,
    output ghost_active,
    output [3:0] selected_timbre
);
    reg [1:0] row_index;
    reg [15:0] row_timer;
    reg [3:0] cols_meta, cols_sync;
    reg [15:0] raw_keys;
    reg frame_tick;
    reg [7:0] debounce_count [0:15];
    reg [15:0] reported;
    genvar r;
    // 每行独立三态输出：未选行悬空，减少多键时行间电流冲突；列由外部上拉。
    generate
        for (r=0; r<4; r=r+1) begin : row_pins
            assign rows[r] = (row_index == r) ? 1'b0 : 1'bz;
        end
    endgenerate

    // 扫描器：列先双级同步，再在当前行保持 ROW_CYCLES 后读取。
    // raw_keys 逐行刷新，帧中可能混合新旧行；frame_tick 在第四行更新时置位，
    // 消抖器在下一 clk 边沿观察该脉冲，届时第四行的新 raw_keys 已经生效。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_index <= 0; row_timer <= 0;
            cols_meta <= 4'hf; cols_sync <= 4'hf;
            raw_keys <= 0; frame_tick <= 0;
        end else begin
            cols_meta <= cols;
            cols_sync <= cols_meta;
            frame_tick <= 0;
            if (row_timer == ROW_CYCLES-1) begin
                row_timer <= 0;
                // 物理列低表示按下，故取反；虚拟键已经用1表示按下，无需取反。
                raw_keys[row_index*4 +: 4] <= virtual_enable ? virtual_keys[row_index*4 +: 4] : ~cols_sync;
                row_index <= row_index + 1'b1;
                if (row_index == 3) frame_tick <= 1;
            end else row_timer <= row_timer + 1'b1;
        end
    end

    // Two rows sharing >=2 active columns form an ambiguous rectangle.
    // Keep already-held keys, allow releases, and suppress phantom new notes.
    reg ghost;
    reg [3:0] overlap;
    integer a,b;
    // ghost 组合检测：两行共同有效列至少两列时形成无法区分真实/串通的矩形。
    // 只依据扫描矩形判歧义，不知道哪些角是真键；有二极管的真实矩形也会被抑制。
    // 串通仍可能把已松开的旧键读成1；需硬件隔离解决，软件不是任意多键无鬼键保证。
    // x&(x-1) 清掉最低的一个1，结果非0等价于 x 至少有两个1。
    always @(*) begin
        ghost = 0; overlap = 0;
        for (a=0; a<4; a=a+1)
            for (b=a+1; b<4; b=b+1) begin
                overlap = raw_keys[a*4 +: 4] & raw_keys[b*4 +: 4];
                if ((overlap & (overlap-4'd1)) != 0) ghost = 1;
            end
    end
    assign ghost_active = ghost;
    // 有矩形歧义时，仅保留 raw_keys 与原先已确认 key_state 的交集：
    // 允许旧键继续保持和松开，抑制所有新按下（包括此时真实但无法判定的新键）。
    // 此策略不会凭空复原被串通遮蔽的真实松开，只处理扫描确实读到0的键。
    wire [15:0] candidate = ghost ? (raw_keys & key_state) : raw_keys;
    integer k;
    // 每键独立计数，按下与松开采用相同消抖门槛；只在完整帧脉冲时推进。
    // 候选恢复成当前状态就清计数，因此必须连续 DEBOUNCE_FRAMES 帧才翻转。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_state <= 0;
            for (k=0; k<16; k=k+1) debounce_count[k] <= 0;
        end else if (frame_tick) begin
            for (k=0; k<16; k=k+1) begin
                if (candidate[k] == key_state[k]) debounce_count[k] <= 0;
                else if (debounce_count[k] == DEBOUNCE_FRAMES-1) begin
                    key_state[k] <= candidate[k];
                    debounce_count[k] <= 0;
                end else debounce_count[k] <= debounce_count[k] + 1'b1;
            end
        end
    end

    // 兼容 TWO_BUTTON_SELECT=0 分支为每组保存变体；双键循环分支另存完整4位音色。
// 两种分支都不按住自动重复；实际是否提交由 apply_selection 决定。
    // Ignore multi-selector combinations (including the diagnostic shortcut).
    reg [3:0] control_previous;
    reg [1:0] selected_group;
    reg [1:0] variants [0:3];
    reg selection_started;
    reg [3:0] two_button_timbre;
    // Test shortcuts must not change timbre as their two keys arrive separately.
    reg [3:0] pending_control;
    reg pending_valid,control_chord;
    // ghost 或实体/虚拟来源切换取消候选，直到扫描和消抖状态都确认全松。
    // 不复位 reported/key_state，保证音符释放仍被事件发送器逐个交付。
    reg selector_wait_release,virtual_previous;
    wire selector_source_changed=virtual_enable!=virtual_previous;
    // 只把已消抖的最高四位视为选择键，避免原始触点抖动直接切换音色。
    wire [3:0] control_keys=key_state[15:12];
    wire [3:0] control_rise=control_keys & ~control_previous;
    // 排除全0，并用 x&(x-1)==0 判断恰有一个选择键按下。
    wire control_single=(control_keys!=0) && ((control_keys & (control_keys-4'd1))==0);
    // 松开模式要求：曾按下单键、当前全部松开、期间没有出现键组合变化。
    // 按下模式要求当前是单键且出现新上升沿；持续按住不会自动循环音色。
    wire release_select=SELECT_ON_RELEASE || TWO_BUTTON_SELECT;
    wire select_event=PERFORMANCE_MODE && (release_select ?
        (control_keys==0 && control_previous!=0 && pending_valid && !control_chord) :
        (control_single && (control_rise!=0))) &&
        (!TWO_BUTTON_SELECT || pending_control==4'b0001 || pending_control==4'b0010);
    wire [3:0] selection_keys=release_select?pending_control:control_keys;
    reg [1:0] next_group,next_variant;
    // 组合计算将要选择的组与变体，供选择寄存器及同拍音符事件共用。
    always @(*) begin
        case(selection_keys)
            4'b0001:next_group=0;
            4'b0010:next_group=1;
            4'b0100:next_group=2;
            4'b1000:next_group=3;
            default:next_group=selected_group;
        endcase
        // 切到别组恢复该组记住的变体；第一次选择不递增。
        // 已经开始选择且再次选当前组时，2位加法使变体按0,1,2,3,0循环。
        next_variant=variants[next_group];
        if(selection_started && next_group==selected_group)
            next_variant=variants[next_group]+2'd1;
    end
    // 兼容分组分支高2位为组、低2位为变体；生产双键分支直接用0..15编号。
    assign selected_timbre=TWO_BUTTON_SELECT?two_button_timbre:
        {selected_group,variants[selected_group]};
    wire [3:0] next_timbre=TWO_BUTTON_SELECT ?
        ((selection_keys==4'b0001)?(two_button_timbre-4'd1):(two_button_timbre+4'd1)) :
        {next_group,next_variant};
    // A selector and a playing key detected in one scan use the new choice.
    // 被 suppress_select 拦截时，旁路也必须沿用真正已选择的音色。
    wire apply_selection=select_event && !suppress_select && !ghost &&
                         !selector_source_changed && !selector_wait_release;
    wire [3:0] event_timbre=apply_selection?next_timbre:selected_timbre;
    integer group_index;
    // 选择键跟踪器：松开模式在从全0变成按键时锁存候选单键；
    // 只要后续非零键集合改变（包括追加/改换键），control_chord 就锁存为1，
    // 直到所有选择键松开才清除，防止诊断双键先后到达造成误切音色。
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            control_previous<=0;selected_group<=0;selection_started<=0;
            two_button_timbre<=0;
            pending_control<=0;pending_valid<=0;control_chord<=0;
            selector_wait_release<=0;virtual_previous<=0;
            for(group_index=0;group_index<4;group_index=group_index+1) variants[group_index]<=0;
        end else begin
            control_previous<=control_keys;
            virtual_previous<=virtual_enable;
            if(ghost || selector_source_changed)begin
                pending_valid<=0;control_chord<=1;selector_wait_release<=1;
            end else if(selector_wait_release)begin
                if(key_state==0 && raw_keys==0)begin
                    selector_wait_release<=0;pending_valid<=0;control_chord<=0;
                end
            end else if(release_select) begin
                // 同一边沿 select_event 仍读取清零前的 pending_valid/control_chord，
                // 因而合法单键松开可确认一次，随后候选信息才被清除。
                if(control_keys==0) begin pending_valid<=0;control_chord<=0;end
                else if(control_previous==0) begin
                    pending_control<=control_keys;pending_valid<=control_single;
                    control_chord<=!control_single;
                end else if(control_keys!=pending_control) control_chord<=1;
            end
            if(apply_selection) begin
                if(TWO_BUTTON_SELECT) two_button_timbre<=next_timbre;
                else begin
                    selected_group<=next_group;variants[next_group]<=next_variant;selection_started<=1;
                end
            end
        end
    end

    // 固定音符表，不按键号简单逐半音递增：S1..S12 为60,62,64,65,67,69,
    // 71,72,74,76,77,79；普通模式的S13..S16继续用81,83,84,86。
    function [6:0] key_note;
        input integer key;
        begin
            case(key)
                0: key_note=7'd60;
                1: key_note=7'd62;
                2: key_note=7'd64;
                3: key_note=7'd65;
                4: key_note=7'd67;
                5: key_note=7'd69;
                6: key_note=7'd71;
                7: key_note=7'd72;
                8: key_note=7'd74;
                9: key_note=7'd76;
                10: key_note=7'd77;
                11: key_note=7'd79;
                12: key_note=7'd81;
                13: key_note=7'd83;
                14: key_note=7'd84;
                15: key_note=7'd86;
                default: key_note=60;
            endcase
        end
    endfunction
    // Serialize all changes: simultaneous keys cannot overwrite each other.
    // 事件发送器：reported 记录最后已发送/已处理的状态，每个 clk 只挑最低
    // 编号的一个变化，最多连续16拍处理一批变化；不是只产生帧末的一条事件。
    // 若某键在轮到它前又回到 reported，短暂变化会合并；正常消抖帧远慢于此循环。
    always @(posedge clk or negedge rst_n) begin : events
        integer i;
        reg found;
        if (!rst_n) begin
            reported<=0; note_on<=0; note_off<=0; note<=0; vel_out<=0; timbre_out<=0;
        end else begin
            note_on<=0; note_off<=0; found=0;
            for (i=0; i<16; i=i+1) begin
                if (!found && key_state[i] != reported[i]) begin
                    reported[i]<=key_state[i];
                    // 演奏模式也更新选择键的 reported，但不输出它们的音符事件。
                    if(!PERFORMANCE_MODE || i<12) begin
                        note<=key_note(i); vel_out<=velocity;
                        // 使用当前选择（必要时旁路本拍新选择）；这里没有为按住的
                        // 每个键保存独立音色，松开事件也携带事件发生时的选择。
                        timbre_out<=PERFORMANCE_MODE?event_timbre:i;
                        note_on<=key_state[i]; note_off<=!key_state[i];
                    end
                    found=1;
                end
            end
        end
    end
endmodule
