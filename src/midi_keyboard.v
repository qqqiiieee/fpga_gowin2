`timescale 1ns/1ps
// MIDI 串口键盘适配器，所有逻辑都在 clk 域。硬件路径：
// TINY+32 TRS Type A MIDI OUT -> 电流环接收模块 -> dedicated midi_rx。
// 这里只处理 31250baud 8N1 电平串口，不实现 USB Host，也不做音频/声部分配。
// 协议参考 https://midi.org/summary-of-midi-1-0-messages 。
//
// event_valid && event_ready 的上升沿才交付一个事件；未交付时完整字段稳定。
// 16 项 FIFO 可吸收矩阵优先引起的短背压。释放位图另外保存批量 off，按音高
// 升序逐拍扫描；ready 连续为高时 128 拍=4.741us。背压时允许扫描等待，
// 但串口和控制消息一直解析；实际新音符事件无处存放才置 sticky overflow
// 并立即 panic，绝不悄悄丢掉 noteoff。单纯 ready=0 不被误判成串口故障。
//
// panic 是一拍的紧急“全局静音”：main 必须把它接到含所有输入的音频局部
// reset。panic 清除排队事件/键状态/延音并复位本模块控制值，同时给默认控制
// 值各打一拍 valid。故障原因 framing_error/overflow 仅 rst_n 可清除。
// panic 和 suppress 上升沿是撤销旧 valid 的明确边界；接收端需让局部 reset
// 优先于该沿可能接到的旧事件。suppress 本身绝不产生全局 panic。
//
// held_notes 只表示本模块认可的物理按键，松键即清；pending_release 只存
// 已松开但踏板仍按住的音符。另有 release_notes 保存待入队的批量释放、
// delivered_notes 记录已经握手给下游的门控，供 suppress 精确释放本来源。
// blocked_notes 记录 suppress 之前/期间仍按住的键，退出后必须先松再重按。
// 不按 32 复音缩减 0..127 音域，也不分配 16 通道的状态数组。
module midi_keyboard #(
    parameter integer CLK_HZ = 27000000,
    parameter integer MIDI_CHANNEL = 0,
    parameter integer DRUM_CHANNEL = 9,
    parameter integer ACTIVE_SENSE_MS = 350,
    parameter integer MAPPING_ENABLE = 0
)(
    input wire clk, rst_n, rx, suppress,
    input wire event_ready,
    output reg event_valid, event_on, event_off,
    output reg [6:0] event_note,
    output reg [7:0] event_velocity,
    output reg [127:0] held_notes,
    output reg program_valid,
    output reg timbre_select,
    output reg volume_valid,
    output reg [7:0] volume,
    output reg bend_valid,
    output reg signed [8:0] bend,
    output reg [6:0] modulation,
    output reg hit0, hit1,
    output reg [7:0] drum_velocity0, drum_velocity1,
    output reg panic,
    output reg framing_error, overflow,
    output reg [7:0] received_count,
    // 追加端口，旧命名端口实例可保持不变。CC字段保持到下一条真实CC；
    // cc_valid仅一拍，不随Panic恢复默认控制值而伪造消息，suppress期间不发。
    // Panic最高优先级，同拍撤销新CC/鼓/镲事件（也包括触发Panic的CC120）。
    output reg cc_valid,
    output reg [6:0] cc_number, cc_value,
    output reg hat_closed_hit, hat_open_hit,
    output reg [7:0] hat_closed_velocity, hat_open_velocity,
    // Mapping config is staged externally. Inputs must be stable at commit handshake.
    // addr={bank,index[6:0]}; writes/commit are accepted ONLY with their ready high.
    input wire mapping_enable, mapping_bank, mapping_commit,
    input wire mapping_wr_en, input wire [7:0] mapping_wr_addr,
    input wire [6:0] mapping_wr_data,
    input wire [27:0] mapping_pad_notes, mapping_cc_numbers,
    output wire mapping_wr_ready, mapping_commit_ready, mapping_commit_ack,
    output wire receipt_note_on, output wire [6:0] receipt_note
);
    wire [7:0] rx_data;
    wire rx_valid, rx_error;
    midi_uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(31250)) receiver (
        .clk(clk), .rst_n(rst_n), .rx(rx), .data(rx_data),
        .data_valid(rx_valid), .framing_error(rx_error)
    );

    // The build-time switch removes the table entirely in old standalone instances.
    // Runtime enable/bank/Pad/CC values are atomic COMMITTED state, never live edits.
    // held/pending/release/delivered/blocked bitmaps remain RAW-note indexed. Only
    // outgoing melody note numbers are mapped. Thus display/physical-held semantics
    // survive remapping; optical strum's held-note chord remains raw as before.
    wire map_enabled;
    wire [6:0] map_first, map_scan;
    wire scan_lookup_ready, mapping_commit_accept;
    wire [27:0] pad_notes_active, cc_numbers_active;
    wire [6:0] event_raw_note;
    generate if(MAPPING_ENABLE) begin:dynamic_mapping
        reg [6:0] note_map[0:255] /* synthesis syn_ramstyle="block_ram" */;
        reg [6:0] read_q, first_q;
        reg [7:0] read_address_q;
        reg read_valid, note_pending;
        reg enabled, bank, commit_ack, commit_seen;
        reg [27:0] pad_config, cc_config;
        localparam integer IDLE_CYCLES=((CLK_HZ+15625)/31250)*10;
        localparam integer IDLE_BITS=$clog2(IDLE_CYCLES+1);
        reg [IDLE_BITS-1:0] idle_clocks;
        // Initial identity image is configuration-time BRAM initialization, not an
        // asynchronous array reset. A runtime reset leaves memory contents intact.
        integer init_index;
        initial for(init_index=0;init_index<256;init_index=init_index+1)
            note_map[init_index]=init_index & 127;
        wire lookup_first=rx_valid && !rx_data[7] && !in_sysex && common_left==0 &&
            running_status[3:0]==MIDI_CHANNEL &&
            (running_status[7:4]==4'h8 || running_status[7:4]==4'h9) && !have_first;
        wire [7:0] read_address=lookup_first?{bank,rx_data[6:0]}:{bank,scan_note};
        // While enabled, ONLY the inactive bank is writable. No full/read write
        // collision can occur on the active lookup port. Disable+commit first if
        // the host needs to edit that bank. Never reset either memory process.
        assign mapping_wr_ready=rst_n && !mapping_commit &&
                                (!enabled || mapping_wr_addr[7]!=bank);
        assign mapping_commit_ready=rst_n && !commit_seen && !mapping_wr_en && !panic &&
            rx && idle_clocks==IDLE_CYCLES && !rx_valid && !have_first &&
            !in_sysex && common_left==0;
        assign mapping_commit_accept=mapping_commit && mapping_commit_ready;
        assign mapping_commit_ack=commit_ack;
        always @(posedge clk) begin
            if(mapping_wr_en && mapping_wr_ready)
                note_map[mapping_wr_addr]<=mapping_wr_data;
            read_q<=note_map[read_address];
        end
        always @(posedge clk or negedge rst_n) begin
            if(!rst_n) begin
                enabled<=0;bank<=0;commit_ack<=0;commit_seen<=0;
                pad_config<={7'd39,7'd37,7'd38,7'd36};
                cc_config<={7'd74,7'd71,7'd91,7'd93};
                read_address_q<=0;read_valid<=0;note_pending<=0;first_q<=0;
                idle_clocks<=0;
            end else begin
                commit_ack<=mapping_commit_accept;
                if(!mapping_commit)commit_seen<=0;
                else if(mapping_commit_accept)commit_seen<=1;
                read_address_q<=read_address;read_valid<=1;
                note_pending<=lookup_first;
                // Sync RAM result is latched one clock AFTER the first data byte;
                // a real 31250baud velocity byte arrives thousands of clocks later.
                if(note_pending)first_q<=read_q;
                if(!rx || rx_valid)idle_clocks<=0;
                else if(idle_clocks<IDLE_CYCLES)idle_clocks<=idle_clocks+1'b1;
                if(mapping_commit_accept) begin
                    enabled<=mapping_enable;bank<=mapping_bank;
                    pad_config<=mapping_pad_notes;cc_config<=mapping_cc_numbers;
                    note_pending<=0;read_valid<=0;
                end
            end
        end
        // scan address tags prevent a release scan from consuming a previous
        // raw-note's synchronous read. A pending first-byte lookup may steal a
        // read slot; scan advancement waits instead of silently skipping an Off.
        assign scan_lookup_ready=!enabled || (read_valid && read_address_q=={bank,scan_note});
        assign map_first=enabled?first_q:first_data;
        assign map_scan=enabled?read_q:scan_note;
        assign map_enabled=enabled;
        assign pad_notes_active=pad_config;
        assign cc_numbers_active=cc_config;
        // Metadata accompanies the unchanged 16-bit event FIFO. Delivered-note
        // bookkeeping must use RAW notes, otherwise suppress would map twice.
        reg [6:0] raw_fifo[0:FIFO_DEPTH-1];
        always @(posedge clk)
            if(push_event && fifo_room)raw_fifo[write_ptr]<=direct_event?first_data:scan_note;
        assign event_raw_note=raw_fifo[read_ptr];
    end else begin:legacy_mapping
        assign map_enabled=0;assign map_first=first_data;assign map_scan=scan_note;
        assign scan_lookup_ready=1;assign mapping_commit_accept=0;
        assign mapping_wr_ready=0;assign mapping_commit_ready=0;assign mapping_commit_ack=0;
        assign pad_notes_active={7'd39,7'd37,7'd38,7'd36};
        assign cc_numbers_active={7'd74,7'd71,7'd91,7'd93};
        assign event_raw_note=event_note;
    end endgenerate
    // Only the four control-bank CCs are normalized to its existing canonical
    // 93/91/71/74 IDs. Built-in CC1/7/64/120/123 always inspect RAW first_data.
    // An explicitly selected reserved CC therefore keeps its original action too.
    // Duplicate custom assignments use the lowest index. Old knob IDs which are
    // not assigned anymore are hidden from the control bank, replacing defaults.
    wire custom_cc_match=first_data==cc_numbers_active[0+:7] ||
        first_data==cc_numbers_active[7+:7] || first_data==cc_numbers_active[14+:7] ||
        first_data==cc_numbers_active[21+:7];
    wire old_knob_cc=first_data==93 || first_data==91 || first_data==71 || first_data==74;
    wire [6:0] routed_cc=!map_enabled?first_data:
        first_data==cc_numbers_active[0+:7]?7'd93:
        first_data==cc_numbers_active[7+:7]?7'd91:
        first_data==cc_numbers_active[14+:7]?7'd71:
        first_data==cc_numbers_active[21+:7]?7'd74:first_data;

    reg [7:0] running_status;
    reg [6:0] first_data;
    reg have_first, in_sysex;
    reg [1:0] common_left;
    wire single_data = (running_status[7:4]==4'hc || running_status[7:4]==4'hd);
    wire complete = rx_valid && !rx_data[7] && !in_sysex && common_left==0 &&
                    running_status[7] && (single_data || have_first);
    wire melody = complete && running_status[3:0]==MIDI_CHANNEL;
    wire drums = complete && running_status[3:0]==DRUM_CHANNEL &&
                 running_status[3:0]!=MIDI_CHANNEL;
    wire key_on = melody && running_status[7:4]==4'h9 && rx_data[6:0]!=0;
    wire key_off = melody && (running_status[7:4]==4'h8 ||
                           (running_status[7:4]==4'h9 && rx_data[6:0]==0));
    wire cc = melody && running_status[7:4]==4'hb;
    wire sustain_up = cc && first_data==64 && !rx_data[6];
    wire all_notes_off = cc && first_data==123;
    wire all_sound_off = cc && first_data==120;
    wire [7:0] expanded_velocity = {rx_data[6:0], rx_data[6]};
    // 先显式符号扩展到 15 位再减中点，算术右移后截取低 9 位。
    wire signed [14:0] bend_centered = $signed({1'b0,rx_data[6:0],first_data})-15'sd8192;

    reg sustain_down, suppress_d;
    reg [127:0] pending_release, release_notes, delivered_notes, blocked_notes;
    reg scan_active;
    reg [6:0] scan_note;
    wire entering_suppress = suppress && !suppress_d;
    wire [127:0] note_mask = (128'b1 << first_data);

    // FIFO 仅存 {on, note[6:0], velocity[7:0]}，off 由 on 反相得到。
    // 内存不逐项异步复位，只有计数/指针复位，有利于映射小型分布 RAM。
    localparam integer FIFO_DEPTH=16;
    reg [15:0] event_fifo [0:FIFO_DEPTH-1];
    reg [3:0] write_ptr, read_ptr;
    reg [4:0] fifo_count;
    wire [15:0] fifo_front = event_fifo[read_ptr];
    wire pop_event = event_valid && event_ready;
    wire fifo_room = fifo_count<FIFO_DEPTH || pop_event;
    wire direct_event = !suppress && !entering_suppress && !blocked_notes[first_data] &&
                        (key_on || (key_off && !sustain_down &&
                         (held_notes[first_data] || pending_release[first_data])));
    // 新字节的 note 优先于释放扫描。实际串行每字节至少 320us，正常情况下
    // 扫描在下一字节前已经完成；背压时新按同音会取消尚未入队的旧 off。
    // 已经入 FIFO 的旧 off 严格排在新 on 前，不会从后面误关新音。
    wire scan_offer = scan_active && release_notes[scan_note] && !direct_event &&
                      !sustain_up && !all_notes_off && !entering_suppress && scan_lookup_ready;
    wire push_event = direct_event || (scan_offer && fifo_room);
    wire [15:0] push_data = direct_event ? {key_on,map_first,expanded_velocity} :
                                           {1'b0,map_scan,8'b0};
    wire fifo_overrun = direct_event && !fifo_room;

    always @(*) begin
        event_valid = (fifo_count!=0);
        event_on = 0;
        event_off = 0;
        event_note = 0;
        event_velocity = 0;
        if (fifo_count!=0) begin
            event_on = fifo_front[15];
            event_off = !fifo_front[15];
            event_note = fifo_front[14:8];
            event_velocity = fifo_front[7:0];
        end
    end

    // Active Sensing 可选：第一次 FE 才武装；武装后任意有效 MIDI 字节续期。
    // 用户指定默认 350ms（MIDI.org 摘要写 300ms），参数为 0 可完全关闭。
    // 先除 1000 再乘毫秒，避免 27,000,000*350 超过 32 位有符号常量。
    localparam integer SENSE_CYCLES_RAW = (CLK_HZ/1000)*ACTIVE_SENSE_MS;
    localparam integer SENSE_CYCLES = SENSE_CYCLES_RAW<1 ? 1 : SENSE_CYCLES_RAW;
    localparam integer SENSE_BITS = SENSE_CYCLES<2 ? 1 : $clog2(SENSE_CYCLES);
    reg sense_enabled;
    reg [SENSE_BITS-1:0] sense_timer;
    wire sense_timeout = ACTIVE_SENSE_MS>0 && sense_enabled && !rx_valid &&
                         sense_timer==SENSE_CYCLES-1;
    wire system_reset = rx_valid && rx_data==8'hff;
    wire transport_stop = rx_valid && rx_data==8'hfc;
    wire panic_request = rx_error || fifo_overrun || sense_timeout ||
                         system_reset || transport_stop || all_sound_off || mapping_commit_accept;

    // Fresh raw-pitch NoteOn, before audio FIFO; excludes drums, velocity0,
    // blocked keys, suppressed/failed bytes and parser cancellation.
    assign receipt_note_on=rst_n && direct_event && key_on && !panic_request;
    assign receipt_note=first_data;

    // V047 CE/SOP candidate. Three point-written maps share write data and
    // use per-bit enables (no 128-bit feedback mux). Bulk-map priorities are
    // factored into common scalar controls, then expressed as independent SOPs.
    // All operands are OLD clock-edge values. No extra state or pipeline stage.
    wire bitmap_accepted_on=key_on && !suppress && !blocked_notes[first_data];
    wire bitmap_deferred_off=key_off && !suppress && !blocked_notes[first_data] &&
        sustain_down && (held_notes[first_data] || pending_release[first_data]);
    wire bitmap_note_write=bitmap_accepted_on || key_off;
    wire bitmap_held_clear=panic_request || entering_suppress || all_notes_off;
    wire bitmap_pending_clear=bitmap_held_clear || sustain_up;
    wire bitmap_held_data=bitmap_accepted_on && !bitmap_held_clear;
    wire bitmap_pending_data=bitmap_deferred_off && !bitmap_pending_clear;
    wire bitmap_delivered_data=event_on && !panic_request;

    // scan_offer already excludes direct notes, sustain-up, CC123 and suppress
    // entry, and already includes the synchronous mapping lookup tag check.
    wire bitmap_scan_clear=scan_offer && fifo_room;
    wire bitmap_release_keep=!panic_request && !entering_suppress;
    wire bitmap_release_pending=bitmap_release_keep && (sustain_up || all_notes_off);
    wire bitmap_release_held=bitmap_release_keep && all_notes_off;
    wire bitmap_release_delivered=!panic_request && entering_suppress;
    wire bitmap_release_pop_on=bitmap_release_delivered && pop_event && event_on;
    wire bitmap_release_pop_off=pop_event && !event_on;

    // Panic must use OLD held even when a simultaneous raw NoteOff or suppress
    // would otherwise clear it. Gate point edits off during panic explicitly.
    wire bitmap_block_keep=!panic_request || suppress;
    wire bitmap_block_import=(panic_request && suppress) || (!panic_request && entering_suppress);
    wire bitmap_block_on=key_on && suppress && !panic_request;
    wire bitmap_block_off=key_off && !panic_request;

    genvar bitmap_i;
    generate for(bitmap_i=0;bitmap_i<128;bitmap_i=bitmap_i+1) begin: bitmap_bits
        wire note_select=(first_data==bitmap_i);
        wire scan_select=(scan_note==bitmap_i);
        wire delivered_select=(event_raw_note==bitmap_i);
        wire note_write=note_select && bitmap_note_write;
        wire delivered_write=delivered_select && pop_event;
        wire release_clear=(note_select && bitmap_accepted_on) ||
                           (scan_select && bitmap_scan_clear);
        wire block_off=note_select && bitmap_block_off;
        always @(posedge clk or negedge rst_n) begin
            if(!rst_n) begin
                held_notes[bitmap_i]<=0;
                pending_release[bitmap_i]<=0;
                delivered_notes[bitmap_i]<=0;
            end else begin
                if(bitmap_held_clear || note_write)
                    held_notes[bitmap_i]<=bitmap_held_data;
                if(bitmap_pending_clear || note_write)
                    pending_release[bitmap_i]<=bitmap_pending_data;
                if(panic_request || delivered_write)
                    delivered_notes[bitmap_i]<=bitmap_delivered_data;
            end
        end
        always @(posedge clk or negedge rst_n) begin
            if(!rst_n) begin
                release_notes[bitmap_i]<=0;
                blocked_notes[bitmap_i]<=0;
            end else begin
                release_notes[bitmap_i]<=
                    (bitmap_release_keep && release_notes[bitmap_i] && !release_clear) ||
                    (bitmap_release_pending && pending_release[bitmap_i]) ||
                    (bitmap_release_held && held_notes[bitmap_i]) ||
                    (bitmap_release_delivered && delivered_notes[bitmap_i] &&
                        !(delivered_select && bitmap_release_pop_off)) ||
                    (bitmap_release_pop_on && delivered_select);
                blocked_notes[bitmap_i]<=
                    (bitmap_block_keep && blocked_notes[bitmap_i] && !block_off) ||
                    (bitmap_block_import && held_notes[bitmap_i] && !block_off) ||
                    (bitmap_block_on && note_select);
            end
        end
    end endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running_status<=0; first_data<=0; have_first<=0; in_sysex<=0; common_left<=0;
            sustain_down<=0; suppress_d<=0;
            scan_active<=0; scan_note<=0;
            write_ptr<=0; read_ptr<=0; fifo_count<=0;
            sense_enabled<=0; sense_timer<=0;
            program_valid<=0; timbre_select<=0; volume_valid<=0; volume<=255;
            bend_valid<=0; bend<=0; modulation<=0;
            hit0<=0; hit1<=0; drum_velocity0<=0; drum_velocity1<=0;
            panic<=0; framing_error<=0; overflow<=0; received_count<=0;
            cc_valid<=0; cc_number<=0; cc_value<=0;
            hat_closed_hit<=0; hat_open_hit<=0;
            hat_closed_velocity<=0; hat_open_velocity<=0;
        end else begin
            suppress_d<=suppress;
            program_valid<=0; volume_valid<=0; bend_valid<=0;
            hit0<=0; hit1<=0; drum_velocity0<=0; drum_velocity1<=0; panic<=0;
            cc_valid<=0;
            hat_closed_hit<=0; hat_open_hit<=0;
            hat_closed_velocity<=0; hat_open_velocity<=0;
            if (rx_valid) received_count<=received_count+1'b1;
            if (rx_error) framing_error<=1;
            if (fifo_overrun) overflow<=1;

            if (rx_valid) begin
                sense_timer<=0;
                if (rx_data==8'hfe && ACTIVE_SENSE_MS>0) sense_enabled<=1;
            end else if (sense_enabled) sense_timer<=sense_timer+1'b1;

            // F8..FF 实时字节不参与长度计数，也不破坏 running status、半包
            // 或 SysEx。FF 的复位例外在后面的最高优先级分支明确处理。
            if (rx_valid && rx_data<8'hf8) begin
                if (rx_data[7]) begin
                    have_first<=0;
                    first_data<=0;
                    common_left<=0;
                    in_sysex<=0;
                    if (rx_data<8'hf0) running_status<=rx_data;
                    else begin
                        running_status<=0;
                        case (rx_data)
                            8'hf0: in_sysex<=1;
                            8'hf1,8'hf3: common_left<=1;
                            8'hf2: common_left<=2;
                            default: common_left<=0; // F4/F5/F6/F7 无数据。
                        endcase
                    end
                end else if (!in_sysex) begin
                    if (common_left!=0) common_left<=common_left-1'b1;
                    else if (running_status[7]) begin
                        if (single_data || have_first) have_first<=0;
                        else begin first_data<=rx_data[6:0]; have_first<=1; end
                    end
                end
            end

            if (pop_event) begin
                read_ptr<=read_ptr+1'b1;

            end
            if (push_event && fifo_room) begin
                event_fifo[write_ptr]<=push_data;
                write_ptr<=write_ptr+1'b1;
            end
            case ({push_event && fifo_room,pop_event})
                2'b10: fifo_count<=fifo_count+1'b1;
                2'b01: fifo_count<=fifo_count-1'b1;
                default: ;
            endcase

            if (scan_active && !direct_event && !sustain_up && !all_notes_off) begin
                if (!release_notes[scan_note] || (fifo_room && scan_lookup_ready)) begin

                    if (scan_note==127) begin scan_active<=0; scan_note<=0; end
                    else scan_note<=scan_note+1'b1;
                end
            end

            // 延音期间 off 只更新位图，不得送到音频；这一条件同时用于下面
            // FIFO 请求，确保 held 的变化与实际发送的事件是同一套语义。
            // 旁路观察已完成的主旋律通道CC，不修改原CC7/CC1/踏板等路径。
            // complete已处理running status、实时插入、半包和通道长度。
            // CC120同样先被解码，但后面最高优先级Panic会撤销本拍通用CC。
            if (cc && !suppress && !rx_error &&
                (!map_enabled || custom_cc_match || !old_knob_cc)) begin
                cc_valid<=1; cc_number<=routed_cc; cc_value<=rx_data[6:0];
            end
            if (cc) case (first_data)
                1: modulation<=rx_data[6:0];
                7: begin volume<=expanded_velocity; volume_valid<=1; end
                64: begin
                    sustain_down<=rx_data[6] && !suppress;
                    if (!rx_data[6]) begin

                        scan_active<=1; scan_note<=0;
                    end
                end
                123: begin
                    sustain_down<=0;
                    scan_active<=1; scan_note<=0;
                end
                default: ;
            endcase
            if (melody && running_status[7:4]==4'hc && rx_data[6:0]<2) begin
                timbre_select<=rx_data[0]; program_valid<=1;
            end
            if (melody && running_status[7:4]==4'he) begin
                bend<=bend_centered >>> 5; bend_valid<=1;
            end
            if (drums && running_status[7:4]==4'h9 && rx_data[6:0]!=0 && !suppress) begin
                if(map_enabled) begin
                    if(first_data==pad_notes_active[0+:7]) begin hit0<=1;drum_velocity0<=expanded_velocity;end
                    else if(first_data==pad_notes_active[7+:7]) begin hit1<=1;drum_velocity1<=expanded_velocity;end
                    else if(first_data==pad_notes_active[14+:7]) begin hat_closed_hit<=1;hat_closed_velocity<=expanded_velocity;end
                    else if(first_data==pad_notes_active[21+:7]) begin hat_open_hit<=1;hat_open_velocity<=expanded_velocity;end
                end else case (first_data)
                    35,36: begin hit0<=1; drum_velocity0<=expanded_velocity; end
                    38,40: begin hit1<=1; drum_velocity1<=expanded_velocity; end
                    // stock Bank A为36/37/38/39；同时兼容GM的42/46镲音符。
                    37,42: begin hat_closed_hit<=1; hat_closed_velocity<=expanded_velocity; end
                    39,46: begin hat_open_hit<=1; hat_open_velocity<=expanded_velocity; end
                    default: ;
                endcase
            end

            if (entering_suppress) begin
                // 取消尚未握手的 FIFO 内容，只释放已交付的 MIDI 来源门控。
                // 若同沿交付了一个 on，也将它加入释放掩码；同沿 off 则去掉。
                write_ptr<=0; read_ptr<=0; fifo_count<=0;
                sustain_down<=0;
                scan_active<=1; scan_note<=0;
                hit0<=0; hit1<=0; drum_velocity0<=0; drum_velocity1<=0;
                hat_closed_hit<=0; hat_open_hit<=0;
                hat_closed_velocity<=0; hat_open_velocity<=0;
            end

            if (panic_request) begin
                panic<=1;
                // 不能让新控件请求或打击乐在全局静音同拍漏向下游。
                // 旧program/volume/bend的默认值valid保持原行为；它们不是CC事件。
                cc_valid<=0;
                write_ptr<=0; read_ptr<=0; fifo_count<=0;

                sustain_down<=0; scan_active<=0; scan_note<=0;
                timbre_select<=0; volume<=255; bend<=0; modulation<=0;
                program_valid<=1; volume_valid<=1; bend_valid<=1;
                hit0<=0; hit1<=0; drum_velocity0<=0; drum_velocity1<=0;
                hat_closed_hit<=0; hat_open_hit<=0;
                hat_closed_velocity<=0; hat_open_velocity<=0;
                sense_enabled<=0; sense_timer<=0;
                // FC 和 CC120 仍保留协议上下文，符合实时插入/running status；
                // 链路错误、队列丢失、超时、FF 则必须重新收到显式通道状态。
                if (rx_error || fifo_overrun || sense_timeout || system_reset || mapping_commit_accept) begin
                    running_status<=0; have_first<=0; first_data<=0;
                    in_sysex<=0; common_left<=0;
                end
            end
        end
    end
endmodule
