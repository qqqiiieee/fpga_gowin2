// 单模拟编码16键：bit0..15按行对应1,2,3,A,4,5,6,B,7,8,9,C,*,0,#,D。
// 默认中心来自商家10bit参考按给定电气假设换算，未在实物上测量；
// 模块内部未知分压/保护可能改变电压，使用前须逐键运行时校准。
// 每个样本先顺序查找最近/次近中心，再顺序核查候选中心与其他中心的间距，
// 含接收拍共34个clk完成，共用一个绝对差减法器，不生成16路并行减法器。
// 中心合法范围8..4094，允许任意排列；与其他中心间距<12码的候选整档拒绝。
// nearest_gap是候选到其他中心及idle=0的最近距离；接收半宽为
// min(32,nearest_gap>>2)，最低2码。最近/次近样本距离差<=2码也拒绝。
// 这样容差随压缩量程缩小而不重叠；中心<8或间距<12须报告前端不可用。
// raw<4为空闲；接口没有基线写入口，因此不自动学习按住的电平作为空闲。
// valid是“本拍完成非歧义有效判断”的单拍脉冲，包括空闲和尚在消抖的有效候选；
// valid并不等于按键已按下。fault保持最近一次错误，遇有效判断清零：
// 包含过期、中心无效、歧义、不匹配和输入超过处理吞吐的情况。
// 无效/歧义/空闲均立即释放；新键必须连续STABLE_SAMPLES轮有效样本才输出onehot。
// cal_write单拍可随时到达，优先于所有判定，立即释放并取消当前帧/清消抖。
// 运行时仅改centers；复位恢复hex默认。持久保存须主机更新JSON并重新生成hex/编译。
// sample_valid正常相隔至少35clk；更快时取消旧帧并重启最新样本，保守释放。
// STALE_CYCLES从最近sample_valid起计时，超时自动释放；复位后fault=1等待首个结果。
// 固定且恰好落在有效中心的模拟假值无法与真实长按区分，不能据此识别物理断线。
module analog_touch_keypad #(
    parameter STABLE_SAMPLES = 3,
    parameter STALE_CYCLES = 2700000
)(
    input clk,
    input rst_n,
    input sample_valid,
    input [11:0] sample_data,
    input cal_write,
    input [3:0] cal_index,
    input [11:0] cal_value,
    output reg [15:0] keys,
    output reg [11:0] raw_value,
    output reg valid,
    output reg fault
);
    localparam [11:0] IDLE_THRESHOLD = 12'd4;
    localparam [12:0] MATCH_TOLERANCE = 13'd32;
    localparam [12:0] AMBIGUITY_MARGIN = 13'd2;
    localparam [12:0] MIN_SEPARATION = 13'd12;
    localparam STABLE_LIMIT = (STABLE_SAMPLES > 0) ? STABLE_SAMPLES : 1;
    localparam STALE_LIMIT = (STALE_CYCLES > 0) ? STALE_CYCLES : 1;
    localparam STABLE_WIDTH = (STABLE_LIMIT > 1) ? $clog2(STABLE_LIMIT+1) : 1;
    localparam STALE_WIDTH = (STALE_LIMIT > 1) ? $clog2(STALE_LIMIT) : 1;
    localparam [1:0] WAIT_SAMPLE = 0, FIND_NEAREST = 1,
                     CHECK_SPACING = 2, COMMIT_SAMPLE = 3;
    reg [11:0] default_centers [0:15];
    reg [11:0] centers [0:15];
    // 从工程根目录编译/运行；专用runner亦保持这一相对目录结构。
    initial $readmemh("src/touch_centers.hex", default_centers);
    reg [1:0] state;
    reg [3:0] scan_index, best_index, pending_index;
    reg [11:0] work_raw, best_center;
    reg [12:0] best_distance, second_distance;
    reg [12:0] nearest_gap;
    reg table_invalid, spacing_invalid;
    reg [STABLE_WIDTH-1:0] stable_count;
    reg [STALE_WIDTH-1:0] stale_count;
    integer reset_index;

    // 先比较交换大小，再做一次减法；状态机切换左操作数复用同一个算术路径。
    wire [11:0] search_left = (state == CHECK_SPACING) ? best_center : work_raw;
    wire [11:0] search_right = centers[scan_index];
    wire [11:0] larger = (search_left >= search_right) ? search_left : search_right;
    wire [11:0] smaller = (search_left >= search_right) ? search_right : search_left;
    wire [12:0] distance = {1'b0, larger} - {1'b0, smaller};
    wire [12:0] quarter_gap = nearest_gap >> 2;
    wire [12:0] receive_window = (quarter_gap > MATCH_TOLERANCE) ? MATCH_TOLERANCE :
                                ((quarter_gap < 2) ? 13'd2 : quarter_gap);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (reset_index=0; reset_index<16; reset_index=reset_index+1)
                centers[reset_index] <= default_centers[reset_index];
            keys <= 0;
            raw_value <= 0;
            valid <= 1'b0;
            fault <= 1'b1;
            state <= WAIT_SAMPLE;
            scan_index <= 0;
            best_index <= 0;
            pending_index <= 0;
            work_raw <= 0;
            best_center <= 0;
            best_distance <= 13'h1fff;
            second_distance <= 13'h1fff;
            nearest_gap <= 0;
            table_invalid <= 1'b0;
            spacing_invalid <= 1'b0;
            stable_count <= 0;
            stale_count <= 0;
        end else begin
            valid <= 1'b0;
            // 原始值始终记录最近输入，包括与校准写入同拍、被取消的样本。
            if (sample_valid) begin
                raw_value <= sample_data;
                stale_count <= 0;
            end else if (stale_count < STALE_LIMIT-1) begin
                stale_count <= stale_count + 1'b1;
            end

            if (cal_write) begin
                centers[cal_index] <= cal_value;
                keys <= 0;
                stable_count <= 0;
                pending_index <= 0;
                state <= WAIT_SAMPLE;
                // 写入后需新判断才恢复有效；范围外中心在下一轮扫描中报告无效。
                fault <= 1'b1;
            end else if (!sample_valid && (stale_count >= STALE_LIMIT-1)) begin
                keys <= 0;
                stable_count <= 0;
                pending_index <= 0;
                state <= WAIT_SAMPLE;
                fault <= 1'b1;
            end else if (sample_valid) begin
                if (state != WAIT_SAMPLE) begin
                    keys <= 0;
                    stable_count <= 0;
                    fault <= 1'b1;
                end
                work_raw <= sample_data;
                state <= FIND_NEAREST;
                scan_index <= 0;
                best_index <= 0;
                best_center <= 0;
                best_distance <= 13'h1fff;
                second_distance <= 13'h1fff;
                table_invalid <= 1'b0;
                spacing_invalid <= 1'b0;
            end else begin
                case (state)
                    FIND_NEAREST: begin
                        if ((centers[scan_index] < 8) || (centers[scan_index] > 4094))
                            table_invalid <= 1'b1;
                        if (distance < best_distance) begin
                            second_distance <= best_distance;
                            best_distance <= distance;
                            best_index <= scan_index;
                            best_center <= centers[scan_index];
                        end else if (distance < second_distance) begin
                            second_distance <= distance;
                        end
                        if (scan_index == 15) begin
                            // 本拍可能刚找到新的最近项，不能使用尚未更新的best_center。
                            nearest_gap <= (distance < best_distance) ?
                                           {1'b0, centers[scan_index]} : {1'b0, best_center};
                            scan_index <= 0;
                            state <= CHECK_SPACING;
                        end else scan_index <= scan_index + 1'b1;
                    end
                    CHECK_SPACING: begin
                        if (scan_index != best_index) begin
                            if (distance < nearest_gap) nearest_gap <= distance;
                            if (distance < MIN_SEPARATION) spacing_invalid <= 1'b1;
                        end
                        if (scan_index == 15)
                            state <= COMMIT_SAMPLE;
                        else scan_index <= scan_index + 1'b1;
                    end
                    COMMIT_SAMPLE: begin
                        state <= WAIT_SAMPLE;
                        if (table_invalid) begin
                            keys <= 0;
                            stable_count <= 0;
                            fault <= 1'b1;
                        end else if (work_raw < IDLE_THRESHOLD) begin
                            keys <= 0;
                            stable_count <= 0;
                            fault <= 1'b0;
                            valid <= 1'b1;
                        end else if (spacing_invalid || (best_distance > receive_window) ||
                                     (second_distance <= best_distance + AMBIGUITY_MARGIN)) begin
                            keys <= 0;
                            stable_count <= 0;
                            fault <= 1'b1;
                        end else begin
                            valid <= 1'b1;
                            fault <= 1'b0;
                            if ((stable_count == 0) || (pending_index != best_index)) begin
                                pending_index <= best_index;
                                stable_count <= 1;
                                keys <= (STABLE_LIMIT == 1) ? (16'h0001 << best_index) : 16'h0000;
                            end else begin
                                if (stable_count < STABLE_LIMIT)
                                    stable_count <= stable_count + 1'b1;
                                if (stable_count >= STABLE_LIMIT-1)
                                    keys <= 16'h0001 << best_index;
                            end
                        end
                    end
                    default: state <= WAIT_SAMPLE;
                endcase
            end
        end
    end
endmodule
