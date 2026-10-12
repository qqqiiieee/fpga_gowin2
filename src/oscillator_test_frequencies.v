// 32路测试频率表：只输出24位DDS步长，不保存或播放音频。
// Fs=93750Hz，目标f=400+97*index。频率整数在生成表时换算，无运行时乘除器。
// 实际频率为increment*93750/2^24，24位相位量化误差小于0.003Hz。
// 纯组合模块，无clk/复位/clock enable/模块参数/valid或相位寄存器。
// index 是无符号声部号0..31，increment 是每音频帧加一次的相位码，不是Hz。
// 这里只查固定常数，32份独立相位保存在共享 wavetable_synth，轮流使用计算链。
module oscillator_test_frequencies(input [4:0] index,output reg [23:0] increment);
// case/default 完整赋值；频率换算已经离线完成，运行时不做乘除或累计相位。
always @(*) begin
    case(index)
        5'd0: increment=24'd71583; // 400Hz
        5'd1: increment=24'd88942; // 497Hz
        5'd2: increment=24'd106300; // 594Hz
        5'd3: increment=24'd123659; // 691Hz
        5'd4: increment=24'd141018; // 788Hz
        5'd5: increment=24'd158377; // 885Hz
        5'd6: increment=24'd175736; // 982Hz
        5'd7: increment=24'd193095; // 1079Hz
        5'd8: increment=24'd210453; // 1176Hz
        5'd9: increment=24'd227812; // 1273Hz
        5'd10: increment=24'd245171; // 1370Hz
        5'd11: increment=24'd262530; // 1467Hz
        5'd12: increment=24'd279889; // 1564Hz
        5'd13: increment=24'd297248; // 1661Hz
        5'd14: increment=24'd314606; // 1758Hz
        5'd15: increment=24'd331965; // 1855Hz
        5'd16: increment=24'd349324; // 1952Hz
        5'd17: increment=24'd366683; // 2049Hz
        5'd18: increment=24'd384042; // 2146Hz
        5'd19: increment=24'd401400; // 2243Hz
        5'd20: increment=24'd418759; // 2340Hz
        5'd21: increment=24'd436118; // 2437Hz
        5'd22: increment=24'd453477; // 2534Hz
        5'd23: increment=24'd470836; // 2631Hz
        5'd24: increment=24'd488195; // 2728Hz
        5'd25: increment=24'd505553; // 2825Hz
        5'd26: increment=24'd522912; // 2922Hz
        5'd27: increment=24'd540271; // 3019Hz
        5'd28: increment=24'd557630; // 3116Hz
        5'd29: increment=24'd574989; // 3213Hz
        5'd30: increment=24'd592348; // 3310Hz
        5'd31: increment=24'd609706; // 3407Hz
        default: increment=0;
    endcase
end
endmodule
