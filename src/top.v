// ============================================================
// top.v
// 顶层：多音色电子乐器引擎
// 引脚对应 Tang Primer 20K Dock（GW2A-LV18PG256C8/I7）
// ============================================================
module top(
    input        clk,       // H11, 27MHz
    input  [1:0] keys,      // T10=keys[0], T3=keys[1]（按下为低）
    output       hp_bck,    // N15
    output       hp_ws,     // P16
    output       hp_din,    // P15
    output       pa_en      // R16 功放使能
);
    localparam NUM_VOICES = 8;
    localparam VW         = 16;   // 采样位宽

    // ---- 上电自动复位（内部产生，不占用按键）----
    reg [7:0] por_cnt;
    reg       rst_n;
    always @(posedge clk) begin
        if (por_cnt != 8'hFF)
            por_cnt <= por_cnt + 8'd1;
        rst_n <= (por_cnt == 8'hFF);
    end

    // ---- 输入控制 ----
    wire [7:0] velocity;
    // TODO: 接入压力传感器 sensor_interface 后，velocity 由传感器给出
    assign velocity = 8'd255;   // 暂时固定力度（满力度提高音量；接传感器后由传感器给出）

    wire       note_on, note_off;
    wire [6:0] note;
    wire [7:0] vel_out;
    keypad #(.NUM_KEYS(2), .BASE_NOTE(7'd60)) u_keypad(
        .clk(clk), .rst_n(rst_n),
        .keys(keys), .velocity(velocity),
        .note_on(note_on), .note_off(note_off),
        .note(note), .vel_out(vel_out)
    );

    // ---- 复音分配 ----
    wire [NUM_VOICES-1:0]   gate;
    wire [NUM_VOICES*7-1:0] note_bus;
    wire [NUM_VOICES*8-1:0] vel_bus;
    voice_allocator #(.NUM_VOICES(NUM_VOICES)) u_alloc(
        .clk(clk), .rst_n(rst_n),
        .note_on(note_on), .note_off(note_off),
        .note(note), .velocity(vel_out),
        .gate(gate), .note_bus(note_bus), .vel_bus(vel_bus)
    );

    // ---- 音频引擎 ----
    wire fs_tick;
    wire [15:0] sample;
    wire [1:0]  timbre;
    assign timbre = 2'd0;   // 当前音色：0=正弦波表（后续加音色切换逻辑）

    wire [NUM_VOICES*VW-1:0] voice_bus;
    genvar g;
    generate
        for (g = 0; g < NUM_VOICES; g = g + 1) begin : voices
            voice u_voice(
                .clk(clk), .rst_n(rst_n), .fs_tick(fs_tick),
                .gate(gate[g]),
                .note(note_bus[g*7 +: 7]),
                .velocity(vel_bus[g*8 +: 8]),
                .timbre(timbre),
                .sample(voice_bus[g*VW +: VW])
            );
        end
    endgenerate

    mixer #(.NUM_VOICES(NUM_VOICES), .WIDTH(VW)) u_mixer(
        .in_bus(voice_bus),
        .mixed(sample)
    );

    // ---- PT8211 输出 ----
    pt8211_driver u_pt8211(
        .clk(clk), .rst_n(rst_n),
        .sample(sample),
        .bck(hp_bck), .ws(hp_ws), .din(hp_din),
        .fs_tick(fs_tick)
    );

    assign pa_en = 1'b1;
endmodule
