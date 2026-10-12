// 整包跨时钟域握手，适用于慢状态快照而非逐拍无损事件队列。
// WIDTH是状态总位数（默认60，生产252）；两域均异步低有效复位，各域同步释放由父层负责。
// pixel帧边界翻转request，source双级同步后冻结held_status并回送ack。
// ack跨回pixel的两拍稳定期保证held_status不变，随后一次性拷贝pending_status。
// display_status在下一帧边界发布；变化可能合并，最迟约两帧，不撕裂当前帧。
// 同沿新pending不会立即用于display（非阻塞赋值读取旧值），这是相干快照约定。
// 本模块没有ready/valid吞吐保证；SDC必须保留握手同步级例外及整包max_delay。

// Bundled-data toggle handshake. Source bus remains stable until next request.
// Destination applies snapshots only at frame boundaries (no tearing).
module hdmi_status_cdc #(parameter WIDTH=60)(input source_clk,input source_rst_n,input [WIDTH-1:0] source_status,
    input pixel_clk,input pixel_rst_n,input frame_start,output reg [WIDTH-1:0] display_status);
    reg request,ack;
    reg [WIDTH-1:0] held_status,pending_status;
    (* syn_preserve=1 *) reg req_meta,req_sync,ack_meta,ack_sync;
    reg ack_seen;
    always @(posedge source_clk or negedge source_rst_n) begin
        if(!source_rst_n) begin req_meta<=0;req_sync<=0;ack<=0;held_status<=0;end
        else begin
            req_meta<=request;req_sync<=req_meta;
            if(req_sync!=ack) begin held_status<=source_status;ack<=req_sync;end
        end
    end
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if(!pixel_rst_n) begin
            request<=0;ack_meta<=0;ack_sync<=0;ack_seen<=0;
            pending_status<=0;display_status<=0;
        end else begin
            ack_meta<=ack;ack_sync<=ack_meta;
            if(ack_sync!=ack_seen) begin pending_status<=held_status;ack_seen<=ack_sync;end
            if(frame_start) begin
                display_status<=pending_status;
                if(request==ack_sync) request<=!request;
            end
        end
    end
endmodule
