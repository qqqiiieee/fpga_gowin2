// V036: sequential, in-place, radix-2 DIT 512-point real-input FFT.
// clk = 27 MHz; sample_tick = 1/288 clk -> PCM Fs = 93750 Hz (NOT 48 kHz).
// Boxcar-8 decimation -> Fs = 11718.75 Hz; bins = 22.88818359375 Hz.
// The boxcar is cheap, NOT a strong anti-alias filter. No generated clocks.
//
// Memory: one synchronous 1024x16 data RAM and one 1024x16 coefficient ROM.
// No memory resets/clear sweeps: capture overwrites ALL 512 complex samples.
// Coefficient file is ROOT-relative (run/build with project root as cwd):
// src/fft512_twiddle.hex: 512 interleaved real/imag twiddles, then 512 Hann.
// All coefficients are signed Q2.14 (exact +/-1); PCM/data are signed Q16.0.
// One shared signed 16x16 multiplier. Products truncate arithmetically by 14;
// every butterfly truncates by 1 (/2), giving total FFT normalization 1/512.
// 17-bit rotated components and an 18-bit shared add/sub preserve sign/carry.
// bin_level is a monotonic piecewise-log of |Re|+|Im|, NOT calibrated dBFS.
// Frames have dead time during compute/output. enable only admits a new frame;
// once admitted the frame completes regardless of enable. Parent owns bin CDC.
module audio_fft512 (
    input wire clk,
    input wire rst_n,
    input wire sample_tick,
    input wire signed [15:0] pcm,
    input wire enable,
    output reg bin_valid,
    output reg [7:0] bin_index,
    output reg [7:0] bin_level,
    output reg frame_done,
    output wire busy
);
    localparam IDLE=5'd0, CAPTURE=5'd1, WINDOW=5'd2, ZERO_IM=5'd3,
        BF_ADDR=5'd4, BF_RR=5'd5, BF_II=5'd6, BF_IR=5'd7, BF_RI=5'd8,
        BF_URE=5'd9, BF_VRE=5'd10, BF_UIM=5'd11, BF_VIM=5'd12,
        OUT_RE=5'd13, OUT_IM=5'd14, OUT_MAG=5'd15, OUT_LOG=5'd16,
        EMIT=5'd17, FINISH=5'd18;
    reg [4:0] state;
    assign busy = (state != IDLE);

    // index is shared by capture, butterfly-u addressing and bin output.
    reg [8:0] index;
    reg [8:0] step;
    reg [7:0] twiddle;
    wire [8:0] half_span = {step[0],step[1],step[2],step[3],step[4],
                           step[5],step[6],step[7],step[8]};
    wire [8:0] v_index = index | half_span;
    wire [8:0] next_index = (v_index + 9'd1) & ~half_span;
    wire [8:0] reversed = {index[0],index[1],index[2],index[3],index[4],
                          index[5],index[6],index[7],index[8]};
    reg [2:0] phase;
    reg signed [18:0] box_sum;
    wire signed [18:0] box_next = box_sum + {{3{pcm[15]}},pcm};

    reg signed [15:0] hold_value;
    reg signed [16:0] accum, t_real, t_imag;
    reg signed [15:0] data_q, coeff_q;
    reg [9:0] read_addr, coeff_addr, write_addr;
    reg write_en;
    reg [15:0] write_data;
    // Gowin infers BSRAM from synchronous read and clocked write. No resets.
    (* ram_style = "block" *) reg signed [15:0] data_memory [0:1023]
        /* synthesis syn_ramstyle="block_ram" */;
    (* rom_style = "block" *) reg signed [15:0] coefficients [0:1023]
        /* synthesis syn_romstyle="block_rom" */;
    initial $readmemh("src/fft512_twiddle.hex", coefficients);
    always @(posedge clk) begin
        data_q <= data_memory[read_addr];
        coeff_q <= coefficients[coeff_addr];
        if (write_en) data_memory[write_addr] <= write_data;
    end

    wire signed [15:0] mul_input = (state == WINDOW) ? hold_value : data_q;
    wire signed [31:0] product = mul_input * coeff_q;
    // Coefficient magnitude <= 16384, so product>>>14 fits signed 17 bits.
    wire signed [16:0] scaled_product = product[30:14];
    wire [15:0] abs_q = data_q[15] ? (~data_q + 16'd1) : data_q;
    reg signed [17:0] alu_a, alu_b;
    wire subtract = (state==BF_II || state==BF_VRE || state==BF_VIM);
    wire signed [17:0] alu_result = alu_a + (subtract ? ~alu_b : alu_b)
                                   + {{17{1'b0}},subtract};
    always @* begin
        alu_a = {{2{data_q[15]}},data_q};
        alu_b = {{1{t_real[16]}},t_real};
        case (state)
            BF_II, BF_RI: begin
                alu_a = {accum[16],accum};
                alu_b = {scaled_product[16],scaled_product};
            end
            BF_VRE, BF_VIM: alu_a = {{2{hold_value[15]}},hold_value};
            OUT_MAG: begin
                // Unsigned magnitudes: abs(-32768) = 32768, never negative.
                alu_a = {2'b00,hold_value};
                alu_b = {2'b00,abs_q};
            end
            default: begin end
        endcase
        if (state==BF_UIM || state==BF_VIM)
            alu_b = {t_imag[16],t_imag};
    end

    always @* begin
        read_addr = {index,1'b0};
        coeff_addr = {1'b0,twiddle,1'b0};
        write_addr = {index,1'b0};
        write_en = 1'b0;
        write_data = alu_result[16:1]; // signed /2, floor toward -infinity
        case (state)
            IDLE, CAPTURE, WINDOW, ZERO_IM:
                coeff_addr = {1'b1,index};
            default: begin end
        endcase
        case (state)
            BF_ADDR: read_addr = {v_index,1'b0};
            BF_RR: begin
                read_addr = {v_index,1'b1};
                coeff_addr[0] = 1'b1;
            end
            BF_II: read_addr = {v_index,1'b1};
            BF_IR: begin
                read_addr = {v_index,1'b0};
                coeff_addr[0] = 1'b1;
            end
            BF_URE, BF_VRE, OUT_IM, OUT_MAG:
                read_addr = {index,1'b1};
            default: begin end
        endcase
        case (state)
            WINDOW: begin
                write_en = 1'b1;
                write_addr = {reversed,1'b0};
                write_data = product[29:14];
            end
            ZERO_IM: begin
                write_en = 1'b1;
                write_addr = {reversed,1'b1};
                write_data = 16'd0;
            end
            BF_URE, BF_UIM, BF_VRE, BF_VIM: begin
                write_en = 1'b1;
                write_addr = {(state==BF_VRE || state==BF_VIM) ? v_index : index,
                              (state==BF_UIM || state==BF_VIM)};
            end
            default: begin end
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            index <= 9'd0;
            step <= 9'd256;
            twiddle <= 8'd0;
            phase <= 3'd0;
            box_sum <= 19'sd0;
            bin_valid <= 1'b0;
            bin_index <= 8'd0;
            bin_level <= 8'd0;
            frame_done <= 1'b0;
        end else begin
            bin_valid <= 1'b0;
            frame_done <= 1'b0;
            case (state)
                IDLE: if (enable && sample_tick) begin
                    index <= 9'd0;
                    box_sum <= {{3{pcm[15]}},pcm};
                    phase <= 3'd1;
                    state <= CAPTURE;
                end
                CAPTURE: if (sample_tick) begin
                    phase <= phase + 3'd1;
                    if (phase==3'd7) begin
                        hold_value <= box_next[18:3]; // signed average, 8 PCM
                        box_sum <= 19'sd0;
                        state <= WINDOW;
                    end else box_sum <= box_next;
                end
                WINDOW: state <= ZERO_IM;
                ZERO_IM: begin
                    index <= index + 9'd1;
                    state <= CAPTURE;
                    if (index==9'd511) begin
                        index <= 9'd0;
                        step <= 9'd256;
                        twiddle <= 8'd0;
                        state <= BF_ADDR;
                    end
                end
                BF_ADDR: state <= BF_RR;
                BF_RR: begin accum <= scaled_product; state <= BF_II; end
                BF_II: begin t_real <= alu_result[16:0]; state <= BF_IR; end
                BF_IR: begin accum <= scaled_product; state <= BF_RI; end
                BF_RI: begin t_imag <= alu_result[16:0]; state <= BF_URE; end
                BF_URE: begin hold_value <= data_q; state <= BF_VRE; end
                BF_VRE: state <= BF_UIM;
                BF_UIM: begin hold_value <= data_q; state <= BF_VIM; end
                BF_VIM: begin
                    index <= next_index;
                    twiddle <= twiddle + step[7:0];
                    state <= BF_ADDR;
                    if (&v_index) begin
                        index <= 9'd0;
                        twiddle <= 8'd0;
                        step <= {1'b0,step[8:1]};
                        if (step==9'd1) state <= OUT_RE;
                    end
                end
                OUT_RE: state <= OUT_IM; // synchronous read of real
                OUT_IM: begin hold_value <= abs_q; state <= OUT_MAG; end
                OUT_MAG: begin
                    accum <= alu_result[16:0];
                    bin_level <= 8'd240;
                    state <= OUT_LOG;
                end
                OUT_LOG: begin
                    if (accum==17'd0) begin
                        bin_level <= 8'd0;
                        state <= EMIT;
                    end else if (accum[16]) begin
                        bin_level <= 8'd255;
                        state <= EMIT;
                    end else if (accum[15]) begin
                        if (bin_level==8'd0 && accum[14:11]==4'd0)
                            bin_level <= 8'd1;
                        else bin_level <= {bin_level[7:4],accum[14:11]};
                        state <= EMIT;
                    end else begin
                        accum <= {accum[15:0],1'b0};
                        bin_level <= bin_level - 8'd16;
                    end
                end
                EMIT: begin
                    bin_valid <= 1'b1;
                    bin_index <= index[7:0];
                    index <= index + 9'd1;
                    state <= OUT_RE;
                    if (index==9'd255) state <= FINISH;
                end
                FINISH: begin frame_done <= 1'b1; state <= IDLE; end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
