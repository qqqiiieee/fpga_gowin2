// ============================================================
// sine_lut.v
// 正弦波表：256 点全周期表 + 线性插值
// 16bit 相位：phase[15:8]=表索引(0..255)，phase[7:0]=插值小数(0..255)
// 输出 16bit 有符号，范围 ±16383（半量程）
// 表值：entry[i] = round(16383 * sin(2*pi*i/256))
// 插值：out = mag0 + (mag1-mag0)*frac/256，等效约 16bit 相位分辨率
// ============================================================
module sine_lut(
    input  [15:0] phase,   // 接 voice 的 phase[23:8]
    output [15:0] sine
);
    wire [7:0] idx  = phase[15:8];
    wire [7:0] frac = phase[7:0];

    reg signed [15:0] mag0, mag1;
    always @(*) begin
        case (idx)
            8'd  0: begin mag0 = 16'h0000; mag1 = 16'h0192; end
            8'd  1: begin mag0 = 16'h0192; mag1 = 16'h0324; end
            8'd  2: begin mag0 = 16'h0324; mag1 = 16'h04B5; end
            8'd  3: begin mag0 = 16'h04B5; mag1 = 16'h0646; end
            8'd  4: begin mag0 = 16'h0646; mag1 = 16'h07D5; end
            8'd  5: begin mag0 = 16'h07D5; mag1 = 16'h0964; end
            8'd  6: begin mag0 = 16'h0964; mag1 = 16'h0AF1; end
            8'd  7: begin mag0 = 16'h0AF1; mag1 = 16'h0C7C; end
            8'd  8: begin mag0 = 16'h0C7C; mag1 = 16'h0E06; end
            8'd  9: begin mag0 = 16'h0E06; mag1 = 16'h0F8D; end
            8'd 10: begin mag0 = 16'h0F8D; mag1 = 16'h1112; end
            8'd 11: begin mag0 = 16'h1112; mag1 = 16'h1294; end
            8'd 12: begin mag0 = 16'h1294; mag1 = 16'h1413; end
            8'd 13: begin mag0 = 16'h1413; mag1 = 16'h158F; end
            8'd 14: begin mag0 = 16'h158F; mag1 = 16'h1708; end
            8'd 15: begin mag0 = 16'h1708; mag1 = 16'h187E; end
            8'd 16: begin mag0 = 16'h187E; mag1 = 16'h19EF; end
            8'd 17: begin mag0 = 16'h19EF; mag1 = 16'h1B5D; end
            8'd 18: begin mag0 = 16'h1B5D; mag1 = 16'h1CC6; end
            8'd 19: begin mag0 = 16'h1CC6; mag1 = 16'h1E2B; end
            8'd 20: begin mag0 = 16'h1E2B; mag1 = 16'h1F8B; end
            8'd 21: begin mag0 = 16'h1F8B; mag1 = 16'h20E7; end
            8'd 22: begin mag0 = 16'h20E7; mag1 = 16'h223D; end
            8'd 23: begin mag0 = 16'h223D; mag1 = 16'h238E; end
            8'd 24: begin mag0 = 16'h238E; mag1 = 16'h24D9; end
            8'd 25: begin mag0 = 16'h24D9; mag1 = 16'h261F; end
            8'd 26: begin mag0 = 16'h261F; mag1 = 16'h275F; end
            8'd 27: begin mag0 = 16'h275F; mag1 = 16'h2899; end
            8'd 28: begin mag0 = 16'h2899; mag1 = 16'h29CD; end
            8'd 29: begin mag0 = 16'h29CD; mag1 = 16'h2AFA; end
            8'd 30: begin mag0 = 16'h2AFA; mag1 = 16'h2C21; end
            8'd 31: begin mag0 = 16'h2C21; mag1 = 16'h2D41; end
            8'd 32: begin mag0 = 16'h2D41; mag1 = 16'h2E59; end
            8'd 33: begin mag0 = 16'h2E59; mag1 = 16'h2F6B; end
            8'd 34: begin mag0 = 16'h2F6B; mag1 = 16'h3075; end
            8'd 35: begin mag0 = 16'h3075; mag1 = 16'h3178; end
            8'd 36: begin mag0 = 16'h3178; mag1 = 16'h3273; end
            8'd 37: begin mag0 = 16'h3273; mag1 = 16'h3367; end
            8'd 38: begin mag0 = 16'h3367; mag1 = 16'h3452; end
            8'd 39: begin mag0 = 16'h3452; mag1 = 16'h3536; end
            8'd 40: begin mag0 = 16'h3536; mag1 = 16'h3611; end
            8'd 41: begin mag0 = 16'h3611; mag1 = 16'h36E4; end
            8'd 42: begin mag0 = 16'h36E4; mag1 = 16'h37AF; end
            8'd 43: begin mag0 = 16'h37AF; mag1 = 16'h3871; end
            8'd 44: begin mag0 = 16'h3871; mag1 = 16'h392A; end
            8'd 45: begin mag0 = 16'h392A; mag1 = 16'h39DA; end
            8'd 46: begin mag0 = 16'h39DA; mag1 = 16'h3A81; end
            8'd 47: begin mag0 = 16'h3A81; mag1 = 16'h3B20; end
            8'd 48: begin mag0 = 16'h3B20; mag1 = 16'h3BB5; end
            8'd 49: begin mag0 = 16'h3BB5; mag1 = 16'h3C41; end
            8'd 50: begin mag0 = 16'h3C41; mag1 = 16'h3CC4; end
            8'd 51: begin mag0 = 16'h3CC4; mag1 = 16'h3D3E; end
            8'd 52: begin mag0 = 16'h3D3E; mag1 = 16'h3DAE; end
            8'd 53: begin mag0 = 16'h3DAE; mag1 = 16'h3E14; end
            8'd 54: begin mag0 = 16'h3E14; mag1 = 16'h3E71; end
            8'd 55: begin mag0 = 16'h3E71; mag1 = 16'h3EC4; end
            8'd 56: begin mag0 = 16'h3EC4; mag1 = 16'h3F0E; end
            8'd 57: begin mag0 = 16'h3F0E; mag1 = 16'h3F4E; end
            8'd 58: begin mag0 = 16'h3F4E; mag1 = 16'h3F84; end
            8'd 59: begin mag0 = 16'h3F84; mag1 = 16'h3FB0; end
            8'd 60: begin mag0 = 16'h3FB0; mag1 = 16'h3FD3; end
            8'd 61: begin mag0 = 16'h3FD3; mag1 = 16'h3FEB; end
            8'd 62: begin mag0 = 16'h3FEB; mag1 = 16'h3FFA; end
            8'd 63: begin mag0 = 16'h3FFA; mag1 = 16'h3FFF; end
            8'd 64: begin mag0 = 16'h3FFF; mag1 = 16'h3FFA; end
            8'd 65: begin mag0 = 16'h3FFA; mag1 = 16'h3FEB; end
            8'd 66: begin mag0 = 16'h3FEB; mag1 = 16'h3FD3; end
            8'd 67: begin mag0 = 16'h3FD3; mag1 = 16'h3FB0; end
            8'd 68: begin mag0 = 16'h3FB0; mag1 = 16'h3F84; end
            8'd 69: begin mag0 = 16'h3F84; mag1 = 16'h3F4E; end
            8'd 70: begin mag0 = 16'h3F4E; mag1 = 16'h3F0E; end
            8'd 71: begin mag0 = 16'h3F0E; mag1 = 16'h3EC4; end
            8'd 72: begin mag0 = 16'h3EC4; mag1 = 16'h3E71; end
            8'd 73: begin mag0 = 16'h3E71; mag1 = 16'h3E14; end
            8'd 74: begin mag0 = 16'h3E14; mag1 = 16'h3DAE; end
            8'd 75: begin mag0 = 16'h3DAE; mag1 = 16'h3D3E; end
            8'd 76: begin mag0 = 16'h3D3E; mag1 = 16'h3CC4; end
            8'd 77: begin mag0 = 16'h3CC4; mag1 = 16'h3C41; end
            8'd 78: begin mag0 = 16'h3C41; mag1 = 16'h3BB5; end
            8'd 79: begin mag0 = 16'h3BB5; mag1 = 16'h3B20; end
            8'd 80: begin mag0 = 16'h3B20; mag1 = 16'h3A81; end
            8'd 81: begin mag0 = 16'h3A81; mag1 = 16'h39DA; end
            8'd 82: begin mag0 = 16'h39DA; mag1 = 16'h392A; end
            8'd 83: begin mag0 = 16'h392A; mag1 = 16'h3871; end
            8'd 84: begin mag0 = 16'h3871; mag1 = 16'h37AF; end
            8'd 85: begin mag0 = 16'h37AF; mag1 = 16'h36E4; end
            8'd 86: begin mag0 = 16'h36E4; mag1 = 16'h3611; end
            8'd 87: begin mag0 = 16'h3611; mag1 = 16'h3536; end
            8'd 88: begin mag0 = 16'h3536; mag1 = 16'h3452; end
            8'd 89: begin mag0 = 16'h3452; mag1 = 16'h3367; end
            8'd 90: begin mag0 = 16'h3367; mag1 = 16'h3273; end
            8'd 91: begin mag0 = 16'h3273; mag1 = 16'h3178; end
            8'd 92: begin mag0 = 16'h3178; mag1 = 16'h3075; end
            8'd 93: begin mag0 = 16'h3075; mag1 = 16'h2F6B; end
            8'd 94: begin mag0 = 16'h2F6B; mag1 = 16'h2E59; end
            8'd 95: begin mag0 = 16'h2E59; mag1 = 16'h2D41; end
            8'd 96: begin mag0 = 16'h2D41; mag1 = 16'h2C21; end
            8'd 97: begin mag0 = 16'h2C21; mag1 = 16'h2AFA; end
            8'd 98: begin mag0 = 16'h2AFA; mag1 = 16'h29CD; end
            8'd 99: begin mag0 = 16'h29CD; mag1 = 16'h2899; end
            8'd100: begin mag0 = 16'h2899; mag1 = 16'h275F; end
            8'd101: begin mag0 = 16'h275F; mag1 = 16'h261F; end
            8'd102: begin mag0 = 16'h261F; mag1 = 16'h24D9; end
            8'd103: begin mag0 = 16'h24D9; mag1 = 16'h238E; end
            8'd104: begin mag0 = 16'h238E; mag1 = 16'h223D; end
            8'd105: begin mag0 = 16'h223D; mag1 = 16'h20E7; end
            8'd106: begin mag0 = 16'h20E7; mag1 = 16'h1F8B; end
            8'd107: begin mag0 = 16'h1F8B; mag1 = 16'h1E2B; end
            8'd108: begin mag0 = 16'h1E2B; mag1 = 16'h1CC6; end
            8'd109: begin mag0 = 16'h1CC6; mag1 = 16'h1B5D; end
            8'd110: begin mag0 = 16'h1B5D; mag1 = 16'h19EF; end
            8'd111: begin mag0 = 16'h19EF; mag1 = 16'h187E; end
            8'd112: begin mag0 = 16'h187E; mag1 = 16'h1708; end
            8'd113: begin mag0 = 16'h1708; mag1 = 16'h158F; end
            8'd114: begin mag0 = 16'h158F; mag1 = 16'h1413; end
            8'd115: begin mag0 = 16'h1413; mag1 = 16'h1294; end
            8'd116: begin mag0 = 16'h1294; mag1 = 16'h1112; end
            8'd117: begin mag0 = 16'h1112; mag1 = 16'h0F8D; end
            8'd118: begin mag0 = 16'h0F8D; mag1 = 16'h0E06; end
            8'd119: begin mag0 = 16'h0E06; mag1 = 16'h0C7C; end
            8'd120: begin mag0 = 16'h0C7C; mag1 = 16'h0AF1; end
            8'd121: begin mag0 = 16'h0AF1; mag1 = 16'h0964; end
            8'd122: begin mag0 = 16'h0964; mag1 = 16'h07D5; end
            8'd123: begin mag0 = 16'h07D5; mag1 = 16'h0646; end
            8'd124: begin mag0 = 16'h0646; mag1 = 16'h04B5; end
            8'd125: begin mag0 = 16'h04B5; mag1 = 16'h0324; end
            8'd126: begin mag0 = 16'h0324; mag1 = 16'h0192; end
            8'd127: begin mag0 = 16'h0192; mag1 = 16'h0000; end
            8'd128: begin mag0 = 16'h0000; mag1 = 16'hFE6E; end
            8'd129: begin mag0 = 16'hFE6E; mag1 = 16'hFCDC; end
            8'd130: begin mag0 = 16'hFCDC; mag1 = 16'hFB4B; end
            8'd131: begin mag0 = 16'hFB4B; mag1 = 16'hF9BA; end
            8'd132: begin mag0 = 16'hF9BA; mag1 = 16'hF82B; end
            8'd133: begin mag0 = 16'hF82B; mag1 = 16'hF69C; end
            8'd134: begin mag0 = 16'hF69C; mag1 = 16'hF50F; end
            8'd135: begin mag0 = 16'hF50F; mag1 = 16'hF384; end
            8'd136: begin mag0 = 16'hF384; mag1 = 16'hF1FA; end
            8'd137: begin mag0 = 16'hF1FA; mag1 = 16'hF073; end
            8'd138: begin mag0 = 16'hF073; mag1 = 16'hEEEE; end
            8'd139: begin mag0 = 16'hEEEE; mag1 = 16'hED6C; end
            8'd140: begin mag0 = 16'hED6C; mag1 = 16'hEBED; end
            8'd141: begin mag0 = 16'hEBED; mag1 = 16'hEA71; end
            8'd142: begin mag0 = 16'hEA71; mag1 = 16'hE8F8; end
            8'd143: begin mag0 = 16'hE8F8; mag1 = 16'hE782; end
            8'd144: begin mag0 = 16'hE782; mag1 = 16'hE611; end
            8'd145: begin mag0 = 16'hE611; mag1 = 16'hE4A3; end
            8'd146: begin mag0 = 16'hE4A3; mag1 = 16'hE33A; end
            8'd147: begin mag0 = 16'hE33A; mag1 = 16'hE1D5; end
            8'd148: begin mag0 = 16'hE1D5; mag1 = 16'hE075; end
            8'd149: begin mag0 = 16'hE075; mag1 = 16'hDF19; end
            8'd150: begin mag0 = 16'hDF19; mag1 = 16'hDDC3; end
            8'd151: begin mag0 = 16'hDDC3; mag1 = 16'hDC72; end
            8'd152: begin mag0 = 16'hDC72; mag1 = 16'hDB27; end
            8'd153: begin mag0 = 16'hDB27; mag1 = 16'hD9E1; end
            8'd154: begin mag0 = 16'hD9E1; mag1 = 16'hD8A1; end
            8'd155: begin mag0 = 16'hD8A1; mag1 = 16'hD767; end
            8'd156: begin mag0 = 16'hD767; mag1 = 16'hD633; end
            8'd157: begin mag0 = 16'hD633; mag1 = 16'hD506; end
            8'd158: begin mag0 = 16'hD506; mag1 = 16'hD3DF; end
            8'd159: begin mag0 = 16'hD3DF; mag1 = 16'hD2BF; end
            8'd160: begin mag0 = 16'hD2BF; mag1 = 16'hD1A7; end
            8'd161: begin mag0 = 16'hD1A7; mag1 = 16'hD095; end
            8'd162: begin mag0 = 16'hD095; mag1 = 16'hCF8B; end
            8'd163: begin mag0 = 16'hCF8B; mag1 = 16'hCE88; end
            8'd164: begin mag0 = 16'hCE88; mag1 = 16'hCD8D; end
            8'd165: begin mag0 = 16'hCD8D; mag1 = 16'hCC99; end
            8'd166: begin mag0 = 16'hCC99; mag1 = 16'hCBAE; end
            8'd167: begin mag0 = 16'hCBAE; mag1 = 16'hCACA; end
            8'd168: begin mag0 = 16'hCACA; mag1 = 16'hC9EF; end
            8'd169: begin mag0 = 16'hC9EF; mag1 = 16'hC91C; end
            8'd170: begin mag0 = 16'hC91C; mag1 = 16'hC851; end
            8'd171: begin mag0 = 16'hC851; mag1 = 16'hC78F; end
            8'd172: begin mag0 = 16'hC78F; mag1 = 16'hC6D6; end
            8'd173: begin mag0 = 16'hC6D6; mag1 = 16'hC626; end
            8'd174: begin mag0 = 16'hC626; mag1 = 16'hC57F; end
            8'd175: begin mag0 = 16'hC57F; mag1 = 16'hC4E0; end
            8'd176: begin mag0 = 16'hC4E0; mag1 = 16'hC44B; end
            8'd177: begin mag0 = 16'hC44B; mag1 = 16'hC3BF; end
            8'd178: begin mag0 = 16'hC3BF; mag1 = 16'hC33C; end
            8'd179: begin mag0 = 16'hC33C; mag1 = 16'hC2C2; end
            8'd180: begin mag0 = 16'hC2C2; mag1 = 16'hC252; end
            8'd181: begin mag0 = 16'hC252; mag1 = 16'hC1EC; end
            8'd182: begin mag0 = 16'hC1EC; mag1 = 16'hC18F; end
            8'd183: begin mag0 = 16'hC18F; mag1 = 16'hC13C; end
            8'd184: begin mag0 = 16'hC13C; mag1 = 16'hC0F2; end
            8'd185: begin mag0 = 16'hC0F2; mag1 = 16'hC0B2; end
            8'd186: begin mag0 = 16'hC0B2; mag1 = 16'hC07C; end
            8'd187: begin mag0 = 16'hC07C; mag1 = 16'hC050; end
            8'd188: begin mag0 = 16'hC050; mag1 = 16'hC02D; end
            8'd189: begin mag0 = 16'hC02D; mag1 = 16'hC015; end
            8'd190: begin mag0 = 16'hC015; mag1 = 16'hC006; end
            8'd191: begin mag0 = 16'hC006; mag1 = 16'hC001; end
            8'd192: begin mag0 = 16'hC001; mag1 = 16'hC006; end
            8'd193: begin mag0 = 16'hC006; mag1 = 16'hC015; end
            8'd194: begin mag0 = 16'hC015; mag1 = 16'hC02D; end
            8'd195: begin mag0 = 16'hC02D; mag1 = 16'hC050; end
            8'd196: begin mag0 = 16'hC050; mag1 = 16'hC07C; end
            8'd197: begin mag0 = 16'hC07C; mag1 = 16'hC0B2; end
            8'd198: begin mag0 = 16'hC0B2; mag1 = 16'hC0F2; end
            8'd199: begin mag0 = 16'hC0F2; mag1 = 16'hC13C; end
            8'd200: begin mag0 = 16'hC13C; mag1 = 16'hC18F; end
            8'd201: begin mag0 = 16'hC18F; mag1 = 16'hC1EC; end
            8'd202: begin mag0 = 16'hC1EC; mag1 = 16'hC252; end
            8'd203: begin mag0 = 16'hC252; mag1 = 16'hC2C2; end
            8'd204: begin mag0 = 16'hC2C2; mag1 = 16'hC33C; end
            8'd205: begin mag0 = 16'hC33C; mag1 = 16'hC3BF; end
            8'd206: begin mag0 = 16'hC3BF; mag1 = 16'hC44B; end
            8'd207: begin mag0 = 16'hC44B; mag1 = 16'hC4E0; end
            8'd208: begin mag0 = 16'hC4E0; mag1 = 16'hC57F; end
            8'd209: begin mag0 = 16'hC57F; mag1 = 16'hC626; end
            8'd210: begin mag0 = 16'hC626; mag1 = 16'hC6D6; end
            8'd211: begin mag0 = 16'hC6D6; mag1 = 16'hC78F; end
            8'd212: begin mag0 = 16'hC78F; mag1 = 16'hC851; end
            8'd213: begin mag0 = 16'hC851; mag1 = 16'hC91C; end
            8'd214: begin mag0 = 16'hC91C; mag1 = 16'hC9EF; end
            8'd215: begin mag0 = 16'hC9EF; mag1 = 16'hCACA; end
            8'd216: begin mag0 = 16'hCACA; mag1 = 16'hCBAE; end
            8'd217: begin mag0 = 16'hCBAE; mag1 = 16'hCC99; end
            8'd218: begin mag0 = 16'hCC99; mag1 = 16'hCD8D; end
            8'd219: begin mag0 = 16'hCD8D; mag1 = 16'hCE88; end
            8'd220: begin mag0 = 16'hCE88; mag1 = 16'hCF8B; end
            8'd221: begin mag0 = 16'hCF8B; mag1 = 16'hD095; end
            8'd222: begin mag0 = 16'hD095; mag1 = 16'hD1A7; end
            8'd223: begin mag0 = 16'hD1A7; mag1 = 16'hD2BF; end
            8'd224: begin mag0 = 16'hD2BF; mag1 = 16'hD3DF; end
            8'd225: begin mag0 = 16'hD3DF; mag1 = 16'hD506; end
            8'd226: begin mag0 = 16'hD506; mag1 = 16'hD633; end
            8'd227: begin mag0 = 16'hD633; mag1 = 16'hD767; end
            8'd228: begin mag0 = 16'hD767; mag1 = 16'hD8A1; end
            8'd229: begin mag0 = 16'hD8A1; mag1 = 16'hD9E1; end
            8'd230: begin mag0 = 16'hD9E1; mag1 = 16'hDB27; end
            8'd231: begin mag0 = 16'hDB27; mag1 = 16'hDC72; end
            8'd232: begin mag0 = 16'hDC72; mag1 = 16'hDDC3; end
            8'd233: begin mag0 = 16'hDDC3; mag1 = 16'hDF19; end
            8'd234: begin mag0 = 16'hDF19; mag1 = 16'hE075; end
            8'd235: begin mag0 = 16'hE075; mag1 = 16'hE1D5; end
            8'd236: begin mag0 = 16'hE1D5; mag1 = 16'hE33A; end
            8'd237: begin mag0 = 16'hE33A; mag1 = 16'hE4A3; end
            8'd238: begin mag0 = 16'hE4A3; mag1 = 16'hE611; end
            8'd239: begin mag0 = 16'hE611; mag1 = 16'hE782; end
            8'd240: begin mag0 = 16'hE782; mag1 = 16'hE8F8; end
            8'd241: begin mag0 = 16'hE8F8; mag1 = 16'hEA71; end
            8'd242: begin mag0 = 16'hEA71; mag1 = 16'hEBED; end
            8'd243: begin mag0 = 16'hEBED; mag1 = 16'hED6C; end
            8'd244: begin mag0 = 16'hED6C; mag1 = 16'hEEEE; end
            8'd245: begin mag0 = 16'hEEEE; mag1 = 16'hF073; end
            8'd246: begin mag0 = 16'hF073; mag1 = 16'hF1FA; end
            8'd247: begin mag0 = 16'hF1FA; mag1 = 16'hF384; end
            8'd248: begin mag0 = 16'hF384; mag1 = 16'hF50F; end
            8'd249: begin mag0 = 16'hF50F; mag1 = 16'hF69C; end
            8'd250: begin mag0 = 16'hF69C; mag1 = 16'hF82B; end
            8'd251: begin mag0 = 16'hF82B; mag1 = 16'hF9BA; end
            8'd252: begin mag0 = 16'hF9BA; mag1 = 16'hFB4B; end
            8'd253: begin mag0 = 16'hFB4B; mag1 = 16'hFCDC; end
            8'd254: begin mag0 = 16'hFCDC; mag1 = 16'hFE6E; end
            8'd255: begin mag0 = 16'hFE6E; mag1 = 16'h0000; end
            default: begin mag0 = 16'h0000; mag1 = 16'h0000; end
        endcase
    end

    // ---- 线性插值（用 |差值| + 方向，规避有符号乘法陷阱）----
    wire        up       = (mag1 >= mag0);              // 有符号比较
    wire [15:0] diff_abs = up ? (mag1 - mag0) : (mag0 - mag1);
    wire [23:0] prod     = diff_abs * {8'd0, frac};     // ≤ 402*255，远小于 2^24
    wire [15:0] delta    = prod[23:8];                  // >>8
    assign sine = up ? (mag0 + delta) : (mag0 - delta);
endmodule
