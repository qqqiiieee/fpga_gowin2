// ============================================================
// note_table.v
// 音符 → 频率字（相位增量）查表
// 24bit 相位累加器，采样率 52734Hz
// phase_inc = round(freq * 2^24 / 52734)
// 示例：一个八度（MIDI 60=C4 ~ 71=B4），按需扩充更多八度
// ============================================================
module note_table(
    input  [6:0] note,       // MIDI 音符编号
    output reg [23:0] phase_inc
);
    always @(*) begin
        case (note)
            7'd60:  phase_inc = 24'd83233;   // C4  261.63Hz
            7'd61:  phase_inc = 24'd88180;   // C#4 277.18Hz
            7'd62:  phase_inc = 24'd93428;   // D4  293.66Hz
            7'd63:  phase_inc = 24'd98984;   // D#4 311.13Hz
            7'd64:  phase_inc = 24'd104866;  // E4  329.63Hz
            7'd65:  phase_inc = 24'd111109;  // F4  349.23Hz
            7'd66:  phase_inc = 24'd117718;  // F#4 369.99Hz
            7'd67:  phase_inc = 24'd124715;  // G4  392.00Hz
            7'd68:  phase_inc = 24'd132133;  // G#4 415.30Hz
            7'd69:  phase_inc = 24'd139985;  // A4  440.00Hz
            7'd70:  phase_inc = 24'd148308;  // A#4 466.16Hz
            7'd71:  phase_inc = 24'd157128;  // B4  493.88Hz
            default: phase_inc = 24'd0;       // 静音
        endcase
    end
endmodule
