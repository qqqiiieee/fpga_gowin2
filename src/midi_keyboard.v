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
    parameter integer ACTIVE_SENSE_MS = 350
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
    output reg [7:0] hat_closed_velocity, hat_open_velocity
);
    wire [7:0] rx_data;
    wire rx_valid, rx_error;
    midi_uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(31250)) receiver (
        .clk(clk), .rst_n(rst_n), .rx(rx), .data(rx_data),
        .data_valid(rx_valid), .framing_error(rx_error)
    );

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
                      !sustain_up && !all_notes_off && !entering_suppress;
    wire push_event = direct_event || (scan_offer && fifo_room);
    wire [15:0] push_data = direct_event ? {key_on,first_data,expanded_velocity} :
                                           {1'b0,scan_note,8'b0};
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
                         system_reset || transport_stop || all_sound_off;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running_status<=0; first_data<=0; have_first<=0; in_sysex<=0; common_left<=0;
            sustain_down<=0; suppress_d<=0;
            held_notes<=0; pending_release<=0; release_notes<=0;
            delivered_notes<=0; blocked_notes<=0; scan_active<=0; scan_note<=0;
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
                if (event_on) delivered_notes[event_note]<=1;
                else delivered_notes[event_note]<=0;
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
                if (!release_notes[scan_note] || fifo_room) begin
                    if (scan_offer) release_notes[scan_note]<=0;
                    if (scan_note==127) begin scan_active<=0; scan_note<=0; end
                    else scan_note<=scan_note+1'b1;
                end
            end

            if (key_on) begin
                if (suppress) blocked_notes[first_data]<=1;
                else if (!blocked_notes[first_data]) begin
                    held_notes[first_data]<=1;
                    pending_release[first_data]<=0;
                    release_notes[first_data]<=0;
                end
            end
            if (key_off) begin
                blocked_notes[first_data]<=0;
                held_notes[first_data]<=0;
                if (!suppress && !blocked_notes[first_data] && sustain_down &&
                    (held_notes[first_data] || pending_release[first_data]))
                    pending_release[first_data]<=1;
                else pending_release[first_data]<=0;
            end

            // 延音期间 off 只更新位图，不得送到音频；这一条件同时用于下面
            // FIFO 请求，确保 held 的变化与实际发送的事件是同一套语义。
            // 旁路观察已完成的主旋律通道CC，不修改原CC7/CC1/踏板等路径。
            // complete已处理running status、实时插入、半包和通道长度。
            // CC120同样先被解码，但后面最高优先级Panic会撤销本拍通用CC。
            if (cc && !suppress && !rx_error) begin
                cc_valid<=1; cc_number<=first_data; cc_value<=rx_data[6:0];
            end
            if (cc) case (first_data)
                1: modulation<=rx_data[6:0];
                7: begin volume<=expanded_velocity; volume_valid<=1; end
                64: begin
                    sustain_down<=rx_data[6] && !suppress;
                    if (!rx_data[6]) begin
                        release_notes<=release_notes | pending_release;
                        pending_release<=0;
                        scan_active<=1; scan_note<=0;
                    end
                end
                123: begin
                    release_notes<=release_notes | held_notes | pending_release;
                    held_notes<=0; pending_release<=0; sustain_down<=0;
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
                case (first_data)
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
                release_notes<=pop_event ?
                    (event_on ? (delivered_notes | (128'b1<<event_note)) :
                                (delivered_notes & ~(128'b1<<event_note))) : delivered_notes;
                blocked_notes<=key_off ? ((blocked_notes | held_notes) & ~note_mask) :
                               ((blocked_notes | held_notes) | (key_on ? note_mask : 128'b0));
                held_notes<=0; pending_release<=0; sustain_down<=0;
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
                held_notes<=0; pending_release<=0; release_notes<=0; delivered_notes<=0;
                blocked_notes<=suppress ? (blocked_notes | held_notes) : 128'b0;
                sustain_down<=0; scan_active<=0; scan_note<=0;
                timbre_select<=0; volume<=255; bend<=0; modulation<=0;
                program_valid<=1; volume_valid<=1; bend_valid<=1;
                hit0<=0; hit1<=0; drum_velocity0<=0; drum_velocity1<=0;
                hat_closed_hit<=0; hat_open_hit<=0;
                hat_closed_velocity<=0; hat_open_velocity<=0;
                sense_enabled<=0; sense_timer<=0;
                // FC 和 CC120 仍保留协议上下文，符合实时插入/running status；
                // 链路错误、队列丢失、超时、FF 则必须重新收到显式通道状态。
                if (rx_error || fifo_overrun || sense_timeout || system_reset) begin
                    running_status<=0; have_first<=0; first_data<=0;
                    in_sysex<=0; common_left<=0;
                end
            end
        end
    end
endmodule
