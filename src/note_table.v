// 作用：把 7 位音符号组合查表转换为无符号 24 位 DDS 相位增量。
// note 是音符编号，phase_inc 是每次采样累加的相位步长，二者都不是 PCM。
// 工程合成器用 27 MHz 主时钟处理 93.75 kHz 音频帧（每帧 288 个 clk 周期）；
// 相位每帧加一次增量并按 24 位回绕，下游音频位图为 16 位二补码 PCM。
// 本模块无 clk、tick、复位或寄存状态：note 变化即重新给出组合结果。
// 以 A4（note=69）为 440 Hz、十二平均律计算 f=440*2^((note-69)/12)，
// 表内增量 = round(f*2^24/93750)。round 是生成表时的取整，不是运行时硬件运算。
// 实际 DDS 频率由 phase_inc*93750/2^24 决定，整数增量存在量化误差。
// 所列范围为 note=21..108（A0..C8），共 88 个条目；未列编号输出 0。
// 增量为 0 只表示相位不前进，不会在这里自动清除合成器的包络或输出 PCM。
module note_table(input [6:0] note,output reg [23:0] phase_inc);
// 每个 case 分支完整赋值，default 覆盖其他编号，因此该组合查表不需要锁存器。
always @(*) begin case(note)
// 最低三个条目依次为 A0、A#0、B0（21..23）。
7'd21:phase_inc=24'd4921;
7'd22:phase_inc=24'd5214;
7'd23:phase_inc=24'd5524;
// C1 起，24..35 为这一组十二个半音。
7'd24:phase_inc=24'd5852;
7'd25:phase_inc=24'd6200;
7'd26:phase_inc=24'd6569;
7'd27:phase_inc=24'd6960;
7'd28:phase_inc=24'd7374;
7'd29:phase_inc=24'd7812;
7'd30:phase_inc=24'd8277;
7'd31:phase_inc=24'd8769;
7'd32:phase_inc=24'd9290;
7'd33:phase_inc=24'd9843;
7'd34:phase_inc=24'd10428;
7'd35:phase_inc=24'd11048;
// C2 起，36..47 为十二个半音。
7'd36:phase_inc=24'd11705;
7'd37:phase_inc=24'd12401;
7'd38:phase_inc=24'd13138;
7'd39:phase_inc=24'd13920;
7'd40:phase_inc=24'd14747;
7'd41:phase_inc=24'd15624;
7'd42:phase_inc=24'd16553;
7'd43:phase_inc=24'd17538;
7'd44:phase_inc=24'd18580;
7'd45:phase_inc=24'd19685;
7'd46:phase_inc=24'd20856;
7'd47:phase_inc=24'd22096;
// C3 起，48..59 为十二个半音。
7'd48:phase_inc=24'd23410;
7'd49:phase_inc=24'd24802;
7'd50:phase_inc=24'd26277;
7'd51:phase_inc=24'd27839;
7'd52:phase_inc=24'd29495;
7'd53:phase_inc=24'd31248;
7'd54:phase_inc=24'd33107;
7'd55:phase_inc=24'd35075;
7'd56:phase_inc=24'd37161;
7'd57:phase_inc=24'd39371;
7'd58:phase_inc=24'd41712;
7'd59:phase_inc=24'd44192;
// C4 起，60..71 为十二个半音；69 是 440 Hz 的 A4 参考。
7'd60:phase_inc=24'd46820;
7'd61:phase_inc=24'd49604;
7'd62:phase_inc=24'd52553;
7'd63:phase_inc=24'd55678;
7'd64:phase_inc=24'd58989;
7'd65:phase_inc=24'd62497;
7'd66:phase_inc=24'd66213;
7'd67:phase_inc=24'd70150;
7'd68:phase_inc=24'd74322;
7'd69:phase_inc=24'd78741;
7'd70:phase_inc=24'd83423;
7'd71:phase_inc=24'd88384;
// C5 起，72..83 为十二个半音。
7'd72:phase_inc=24'd93639;
7'd73:phase_inc=24'd99208;
7'd74:phase_inc=24'd105107;
7'd75:phase_inc=24'd111357;
7'd76:phase_inc=24'd117978;
7'd77:phase_inc=24'd124994;
7'd78:phase_inc=24'd132426;
7'd79:phase_inc=24'd140301;
7'd80:phase_inc=24'd148643;
7'd81:phase_inc=24'd157482;
7'd82:phase_inc=24'd166847;
7'd83:phase_inc=24'd176768;
// C6 起，84..95 为十二个半音。
7'd84:phase_inc=24'd187279;
7'd85:phase_inc=24'd198415;
7'd86:phase_inc=24'd210213;
7'd87:phase_inc=24'd222713;
7'd88:phase_inc=24'd235957;
7'd89:phase_inc=24'd249987;
7'd90:phase_inc=24'd264852;
7'd91:phase_inc=24'd280601;
7'd92:phase_inc=24'd297287;
7'd93:phase_inc=24'd314964;
7'd94:phase_inc=24'd333693;
7'd95:phase_inc=24'd353535;
// C7 起，96..107 为十二个半音。
7'd96:phase_inc=24'd374558;
7'd97:phase_inc=24'd396830;
7'd98:phase_inc=24'd420427;
7'd99:phase_inc=24'd445427;
7'd100:phase_inc=24'd471913;
7'd101:phase_inc=24'd499975;
7'd102:phase_inc=24'd529705;
7'd103:phase_inc=24'd561203;
7'd104:phase_inc=24'd594573;
7'd105:phase_inc=24'd629929;
7'd106:phase_inc=24'd667386;
7'd107:phase_inc=24'd707071;
// C8 为最高已列音符；更高或更低的未列编号均走 default。
7'd108:phase_inc=24'd749115;
// 未支持音符明确给出零增量；没有 MIDI note_off 或静音状态机语义。
default:phase_inc=0;endcase end endmodule
