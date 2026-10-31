`timescale 1ns/1ps
// Passive final-PCM recording tap, SAME clk domain as the audio sample enable.
// Production: clk=27MHz, sample_tick=93750Hz (one-cycle pulse every288clk).
// Six consecutive signed PCM16 samples -> arithmetic mean, truncating toward0,
// yielding15625Hz mono PCM16. This is a boxcar decimator, NOT an anti-alias codec.
// MAX_SAMPLES defaults to468750 generated outputs =30seconds. The parameter is
// solely a shorter simulation limit; values outside1..468750 clamp to that range.
//
// start: accepted ONLY when busy=0; resets the session, FIFO metadata and CRC.
// active: acquisition only. busy: acquisition OR draining/CRC/EOF waiting.
// stop wins over a same-clock sample_tick. A partial group (<6 input samples)
// is discarded, never padded/averaged as a shorter group and never counted/CRC'd.
// Limit stop includes the final complete six-sample average. start while busy is
// ignored, including when DATA/EOF is stalled; no implicit queued restart exists.
//
// DATA type8'h40: payload[15:0]=sample0,[31:16]=sample1,[47:32]=sample2.
// A final one/two-sample DATA packet has high samples zero-padded. Padding is NOT
// included in count or CRC. EOF type8'h41 follows all DATA, payload={dropped,count}.
// packet_valid/type/payload remain stable until ready. No audio-side ready exists.
//
// sample_count counts ALL valid generated averages, including samples discarded
// on FIFO overflow. dropped saturates at65535; any dropped!=0 makes the recording
// FAILED. There are no gap indices/retransmits; a receiver MUST NOT claim a complete
// WAV after any drop. CRC covers generated samples even when they were dropped,
// so it also cannot accidentally certify only the surviving subsequence.
//
// CRC32 IEEE reflected: polyEDB88320, initFFFFFFFF, final invert. Each average's
// low byte then high byte, LSB-first, is processed serially in16clk. The guaranteed
// production inter-average spacing1728clk leaves ample time. Test clocks MUST keep
// complete averages >=17clk apart. No unrolled16bit/byte XOR network is present.
// EOF waits until that final CRC finishes. pcm_crc32 may change while busy and is
// authoritative once EOF is valid/accepted; stays valid until the NEXT accepted start.
//
// FIFO: ONE512x16 synchronous-read/write array, NO array reset and no asynchronous
// reads. Pointers/count reset invalidates history. At full occupancy a simultaneous
// read does NOT make a same-edge write admissible: this deliberately avoids any
// vendor-dependent same-address read/write collision (the new sample is dropped).
module phone_record_tap #(
    parameter integer MAX_SAMPLES=468750
)(
    input wire clk, rst_n, sample_tick,
    input wire signed [15:0] pcm,
    input wire start, stop,
    output reg active,
    output reg [31:0] sample_count,
    output reg [15:0] dropped,
    output reg packet_valid,
    output reg [7:0] packet_type,
    output reg [47:0] packet_payload,
    input wire packet_ready,
    output wire [31:0] pcm_crc32,
    output reg busy
);
    localparam integer LIMIT=MAX_SAMPLES<1?1:(MAX_SAMPLES>468750?468750:MAX_SAMPLES);
    reg signed [18:0] sum;
    reg [2:0] decimation;
    wire signed [18:0] full_sum=sum+{{3{pcm[15]}},pcm};
    wire signed [18:0] mean_wide=full_sum / 19'sd6;
    wire [15:0] mean_pcm=mean_wide[15:0];
    wire generated=active && !stop && sample_tick && decimation==5;

    reg [15:0] fifo[0:511] /* synthesis syn_ramstyle="block_ram" */;
    reg [8:0] write_ptr,read_ptr;
    reg [9:0] fifo_count;
    reg [15:0] read_q;
    reg read_pending;
    reg [1:0] assembled;
    reg [31:0] assembly_low;
    wire fifo_write=generated && fifo_count<512;
    wire fifo_read=busy && !packet_valid && !read_pending && fifo_count!=0;
    always @(posedge clk) begin
        if(fifo_write)fifo[write_ptr]<=mean_pcm;
        if(fifo_read)read_q<=fifo[read_ptr];
    end

    reg [31:0] crc;
    reg [15:0] crc_shift;
    reg [4:0] crc_bits;
    wire crc_busy=(crc_bits!=0);
    wire [31:0] crc_step=(crc>>1)^((crc[0]^crc_shift[0])?32'hEDB88320:32'd0);
    assign pcm_crc32=~crc;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)begin
            active<=0;busy<=0;sample_count<=0;dropped<=0;
            packet_valid<=0;packet_type<=0;packet_payload<=0;
            sum<=0;decimation<=0;write_ptr<=0;read_ptr<=0;fifo_count<=0;
            read_pending<=0;assembled<=0;assembly_low<=0;
            crc<=32'hFFFFFFFF;crc_shift<=0;crc_bits<=0;
        end else if(start && !busy)begin
            // No memory access is enabled before a session, so stale read_q is
            // harmless. Reset only metadata, NOT fifo[] or its read register.
            active<=1;busy<=1;sample_count<=0;dropped<=0;
            packet_valid<=0;packet_type<=0;packet_payload<=0;
            sum<=0;decimation<=0;write_ptr<=0;read_ptr<=0;fifo_count<=0;
            read_pending<=0;assembled<=0;assembly_low<=0;
            crc<=32'hFFFFFFFF;crc_shift<=0;crc_bits<=0;
        end else begin
            if(crc_busy)begin
                crc<=crc_step;crc_shift<=crc_shift>>1;crc_bits<=crc_bits-1'b1;
            end
            if(active)begin
                if(stop)begin active<=0;sum<=0;decimation<=0;end
                else if(sample_tick)begin
                    if(decimation==5)begin
                        sum<=0;decimation<=0;sample_count<=sample_count+1'b1;
                        if(sample_count==LIMIT-1)active<=0;
                        // Generated PCM enters CRC independently of FIFO success.
                        crc_shift<=mean_pcm;crc_bits<=16;
                        if(!fifo_write && dropped!=16'hFFFF)dropped<=dropped+1'b1;
                    end else begin sum<=full_sum;decimation<=decimation+1'b1;end
                end
            end
            if(fifo_write)write_ptr<=write_ptr+1'b1;
            if(fifo_read)begin read_ptr<=read_ptr+1'b1;read_pending<=1;end
            case({fifo_write,fifo_read})
                2'b10:fifo_count<=fifo_count+1'b1;
                2'b01:fifo_count<=fifo_count-1'b1;
                default:;
            endcase
            // This edge consumes the synchronous RAM result requested LAST edge.
            if(read_pending)begin
                read_pending<=0;
                case(assembled)
                    0:begin assembly_low[15:0]<=read_q;assembled<=1;end
                    1:begin assembly_low[31:16]<=read_q;assembled<=2;end
                    default:begin
                        packet_valid<=1;packet_type<=8'h40;
                        packet_payload<={read_q,assembly_low};
                        assembled<=0;assembly_low<=0;
                    end
                endcase
            end
            if(packet_valid && packet_ready)begin
                packet_valid<=0;
                if(packet_type==8'h41)busy<=0;
            end
            // The final output enters FIFO on the edge active falls. All tests
            // here use OLD active/count/pending, so EOF cannot outrun that write.
            // crc_busy must be false AFTER all16bits; its final state is then
            // already visible before packet_valid can advertise EOF.
            if(busy && !active && fifo_count==0 && !read_pending &&
               !packet_valid && !crc_busy)begin
                packet_valid<=1;
                if(assembled!=0)begin
                    packet_type<=8'h40;
                    packet_payload<=assembled==1?{32'd0,assembly_low[15:0]}:{16'd0,assembly_low};
                    assembled<=0;assembly_low<=0;
                end else begin packet_type<=8'h41;packet_payload<={dropped,sample_count};end
            end
        end
    end
    // synthesis translate_off
    always @(posedge clk)
        if(rst_n && generated && crc_busy)
            $fatal(1,"phone_record_tap: input rate exceeds serial CRC contract");
    // synthesis translate_on
endmodule
