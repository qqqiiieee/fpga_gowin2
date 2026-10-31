// V036 passive visual side branch. Fs=93750 sample_tick from the audio parent.
// voice0/voice1 MUST be independent signed pre-FX voices, never duplicated L/R.
// One 512x8 FFT RAM + one 32768x1 XY RAM: intended 1+2 Gowin BSRAM, no DSP.
// Both memories have one synchronous pixel-clock read and NO RAM reset/init.
// Raw common reset drives ONLY each domain's two ready synchronizer flops.
// Functional controls use local ready[1] as async reset: assertion propagates
// without clocks, release follows ONLY the destination domain's clock edges.
// A stopped pixel clock holds each published bank indefinitely without overwrite.
module audio_visual_buffers #(
    parameter integer XY_AUTO_SCALE=0 // 0保留固定坐标；板级显示显式启用自适应。
)(
    input clk27,input source_rst_n,input pixel_clk,input pixel_rst_n,
    input frame_tick,input sample_tick,input signed [15:0] pcm,voice0,voice1,
    input [7:0] fft_read_addr,input [13:0] xy_read_addr,
    output [7:0] fft_level,output xy_dot,
    output reg fft_valid,output reg xy_valid
);
    wire reset_n=source_rst_n && pixel_rst_n;
    (* async_reg="true", syn_preserve=1 *) reg [1:0] source_ready,pixel_ready;
    always @(posedge clk27 or negedge reset_n)
        if(!reset_n)source_ready<=0;
        else source_ready<={source_ready[0],1'b1};
    always @(posedge pixel_clk or negedge reset_n)
        if(!reset_n)pixel_ready<=0;
        else pixel_ready<={pixel_ready[0],1'b1};

    reg [7:0] fft_ram[0:511] /* synthesis syn_ramstyle="block_ram" */;
    reg xy_ram[0:32767] /* synthesis syn_ramstyle="block_ram" */;
    reg fft_request,xy_request,fft_ack,xy_ack,frame_seen;
    (* async_reg="true", syn_preserve=1 *) reg fft_req_meta,fft_req_sync;
    (* async_reg="true", syn_preserve=1 *) reg xy_req_meta,xy_req_sync;
    (* async_reg="true", syn_preserve=1 *) reg fft_ack_meta,fft_ack_sync;
    (* async_reg="true", syn_preserve=1 *) reg xy_ack_meta,xy_ack_sync;
    wire fft_pending=fft_request!=fft_ack_sync;
    wire xy_pending=xy_request!=xy_ack_sync;
    // The first frame boundary after any reset is ALWAYS invalid, including
    // when the pixel clock was stalled long enough for a capture to complete.
    wire fft_swap=frame_tick && frame_seen && fft_req_sync!=fft_ack;
    wire xy_swap=frame_tick && frame_seen && xy_req_sync!=xy_ack;
    // Select the NEW bank on the swap edge too, so q and valid cannot expose
    // a stale old-bank pixel at the first valid frame boundary.
    wire fft_read_bank=fft_swap ? fft_req_sync : fft_ack;
    wire xy_read_bank=xy_swap ? xy_req_sync : xy_ack;
    reg [7:0] fft_q;
    reg xy_q;
    always @(posedge pixel_clk)begin
        fft_q<=fft_ram[{fft_read_bank,fft_read_addr}];
        xy_q<=xy_ram[{xy_read_bank,xy_read_addr}];
    end
    assign fft_level=fft_valid ? fft_q : 8'd0;
    assign xy_dot=xy_valid ? xy_q : 1'b0;
    always @(posedge pixel_clk or negedge pixel_ready[1])begin
        if(!pixel_ready[1])begin
            fft_req_meta<=0;fft_req_sync<=0;xy_req_meta<=0;xy_req_sync<=0;
            fft_ack<=0;xy_ack<=0;fft_valid<=0;xy_valid<=0;frame_seen<=0;
        end else begin
            fft_req_meta<=fft_request;fft_req_sync<=fft_req_meta;
            xy_req_meta<=xy_request;xy_req_sync<=xy_req_meta;
            if(frame_tick)frame_seen<=1;
            if(fft_swap)begin fft_ack<=fft_req_sync;fft_valid<=1;end
            if(xy_swap)begin xy_ack<=xy_req_sync;xy_valid<=1;end
        end
    end
    always @(posedge clk27 or negedge source_ready[1])begin
        if(!source_ready[1])begin
            fft_ack_meta<=0;fft_ack_sync<=0;xy_ack_meta<=0;xy_ack_sync<=0;
        end else begin
            fft_ack_meta<=fft_ack;fft_ack_sync<=fft_ack_meta;
            xy_ack_meta<=xy_ack;xy_ack_sync<=xy_ack_meta;
        end
    end

    wire bin_valid,frame_done,fft_busy;
    wire [7:0] bin_index,bin_level;
    // frame_done MUST inhibit the idle core in the publication cycle; otherwise
    // an immediate sample_tick can start a capture before pending is registered.
    wire fft_enable=!fft_pending && !frame_done;
    audio_fft512 u_fft(.clk(clk27),.rst_n(source_ready[1]),
        .sample_tick(sample_tick),.pcm(pcm),.enable(fft_enable),
        .bin_valid(bin_valid),.bin_index(bin_index),.bin_level(bin_level),
        .frame_done(frame_done),.busy(fft_busy));
    always @(posedge clk27)
        if(source_ready[1] && bin_valid && !fft_pending)
            fft_ram[{!fft_request,bin_index}]<=bin_level;
    always @(posedge clk27 or negedge source_ready[1])begin
        if(!source_ready[1])fft_request<=0;
        else if(frame_done && !fft_pending)fft_request<=!fft_request;
    end

    localparam [1:0] XY_CLEAR=0,XY_CAPTURE=1,XY_PUBLISH=2,XY_WAIT=3;
    reg [1:0] xy_state;
    reg [13:0] clear_index;
    reg [9:0] point_count;
    // V037：仅改变绘图坐标，不修改送往FFT、混音器或DAC的任何样本。
    // 两轴共用倍率，不能各自归一化，否则会把真实的幅度比例画错。
    // 当前帧测量峰值，发布时决定下一帧倍率；1024点中途不换挡。
    reg [15:0] xy_frame_peak;
    reg [2:0] xy_scale_shift; // 0..4 = x1/x2/x4/x8/x16。
    reg xy_up_pending;       // 连续两帧有余量才升一挡，避免边界附近来回跳。
    wire [15:0] abs_voice0=voice0[15] ? (~voice0+16'd1) : voice0;
    wire [15:0] abs_voice1=voice1[15] ? (~voice1+16'd1) : voice1;
    wire [15:0] pair_peak=abs_voice0>abs_voice1 ? abs_voice0 : abs_voice1;
    wire [2:0] xy_desired_shift=(xy_frame_peak<16'd256) ? 3'd0 :
        (xy_frame_peak<=16'd1536) ? 3'd4 :
        (xy_frame_peak<=16'd3072) ? 3'd3 :
        (xy_frame_peak<=16'd6144) ? 3'd2 :
        (xy_frame_peak<=16'd12288) ? 3'd1 : 3'd0;

    // 等价于sat16(value * 2^shift)先算术右移9位，再加64。
    // 直接选固定切片，避免乘法器；溢出时夹到边界，绝不截断回绕。
    // -32768的绝对值用无符号16位保存，不能误当成负峰值。
    function [6:0] xy_coordinate;
        input signed [15:0] value;
        input [2:0] shift;
        reg fits;
        reg [6:0] mapped;
        begin
            fits=1'b1;mapped={~value[15],value[14:9]};
            case(shift)
                1:begin fits=(value[15:14]=={2{value[15]}});mapped={~value[15],value[13:8]};end
                2:begin fits=(value[15:13]=={3{value[15]}});mapped={~value[15],value[12:7]};end
                3:begin fits=(value[15:12]=={4{value[15]}});mapped={~value[15],value[11:6]};end
                4:begin fits=(value[15:11]=={5{value[15]}});mapped={~value[15],value[10:5]};end
                default:begin end
            endcase
            xy_coordinate=fits ? mapped : (value[15] ? 7'd0 : 7'd127);
        end
    endfunction
    wire [2:0] xy_effective_shift=XY_AUTO_SCALE ? xy_scale_shift : 3'd0;
    wire [6:0] point_x=xy_coordinate(voice0,xy_effective_shift);
    // 屏幕Y向下增长，反转整个坐标，使正幅值朝上。
    wire [6:0] point_y=~xy_coordinate(voice1,xy_effective_shift);
    wire xy_write=source_ready[1] &&
        (xy_state==XY_CLEAR || (xy_state==XY_CAPTURE && sample_tick));
    wire [13:0] xy_write_addr=xy_state==XY_CLEAR ? clear_index : {point_y,point_x};
    always @(posedge clk27)
        if(xy_write)xy_ram[{!xy_request,xy_write_addr}]<=xy_state!=XY_CLEAR;
    always @(posedge clk27 or negedge source_ready[1])begin
        if(!source_ready[1])begin
            xy_request<=0;xy_state<=XY_CLEAR;clear_index<=0;point_count<=0;
            xy_frame_peak<=0;xy_scale_shift<=0;xy_up_pending<=0;
        end else case(xy_state)
            XY_CLEAR:begin
                xy_frame_peak<=0;
                clear_index<=clear_index+1'b1;
                if(&clear_index)begin xy_state<=XY_CAPTURE;point_count<=0;end
            end
            XY_CAPTURE:if(sample_tick)begin
                if(pair_peak>xy_frame_peak)xy_frame_peak<=pair_peak;
                point_count<=point_count+1'b1;
                if(&point_count)xy_state<=XY_PUBLISH;
            end
            XY_PUBLISH:begin
                xy_request<=!xy_request;xy_state<=XY_WAIT;
                if(XY_AUTO_SCALE)begin
                    // 近静音不追着量化噪声放大；变强则下一帧立即缩小。
                    if(xy_frame_peak<16'd256 || xy_desired_shift<xy_scale_shift)begin
                        xy_scale_shift<=xy_desired_shift;xy_up_pending<=0;
                    end else if(xy_desired_shift>xy_scale_shift)begin
                        if(xy_up_pending)begin
                            xy_scale_shift<=xy_scale_shift+1'b1;xy_up_pending<=0;
                        end else xy_up_pending<=1;
                    end else xy_up_pending<=0;
                end
            end
            XY_WAIT:if(!xy_pending)begin xy_state<=XY_CLEAR;clear_index<=0;end
        endcase
    end
endmodule
