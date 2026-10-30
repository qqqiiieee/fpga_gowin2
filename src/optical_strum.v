// SEN0503 gesture front end, clk-domain outputs; no assumption about OUT polarity.
// Wiring contract: each transmitter/receiver red=3V3, black=GND, receiver white=OUT;
// each OUT needs its own external 10k pull-up to 3V3. Use two parallel beams A=bit0,
// B=bit1 spaced 3..5 cm along hand travel. 3V3 range is about 20cm, sensor response
// is 2ms; FPGA filtering adds 1ms at the defaults. Official electrical reference:
// https://www.dfrobot.com.cn/goods-3274.html (does not specify blocked HIGH/LOW).
// IMPORTANT: boot with BOTH paths unobstructed for 200ms. A hand present at boot
// is learned as idle; remove it and RESET. Baselines never adapt after ready.
// One sensor works: keep the unused input pulled to a fixed idle level. It fires
// only after the 150ms pairing timeout, so single-beam fallback IS slower.
module optical_strum #(
    parameter CLK_HZ=27000000,
    parameter FILTER_CYCLES=27000,
    parameter STARTUP_CYCLES=5400000,
    parameter PAIR_WINDOW_CYCLES=4050000
)(
    input clk, input rst_n, input [1:0] beams, input suppress,
    output reg trigger, output reg reverse,
    output reg [7:0] velocity, output reg [3:0] gap_ms,
    output [1:0] blocked, output reg ready,output [1:0] electrical_level
);
    function integer bits_for;
        input integer n;
        integer v;
        begin v=n-1; bits_for=0;
            while(v>0) begin bits_for=bits_for+1; v=v>>1; end
            if(bits_for<1) bits_for=1;
        end
    endfunction
    // Positive cycle counts; clamp tiny test configurations to one clock.
    localparam F=(FILTER_CYCLES<1)?1:FILTER_CYCLES;
    localparam S=(STARTUP_CYCLES<1)?1:STARTUP_CYCLES;
    localparam P=(PAIR_WINDOW_CYCLES<1)?1:PAIR_WINDOW_CYCLES;
    localparam FW=bits_for(F), SW=bits_for(S), PW=bits_for(P);
    // Ceil milliseconds in clock cycles (exact at 27MHz). No ms tick quantization.
    localparam MS=(CLK_HZ<1000)?1:((CLK_HZ+999)/1000);
    (* ASYNC_REG="TRUE" *) reg [1:0] beam_meta, beam_sync;
    reg [1:0] sync_valid;
    reg filter_initialized;
    reg [1:0] filtered, idle_level, previous_blocked;
    reg [FW-1:0] filter_count [0:1];
    reg [SW-1:0] startup_count;
    reg [PW-1:0] pair_age;
    reg [1:0] clear_age; // drain the two CDC stages after leaving suppress
    reg first_b; // 0: A first => ascending, 1: B first => descending.
    localparam CLEAR=0, ARMED=1, PAIR=2, RELEASE=3;
    reg [1:0] state;
    wire [1:0] rising_blocked=blocked & ~previous_blocked;
    assign electrical_level=filtered;
    assign blocked=ready ? (filtered ^ idle_level) : 2'b00;
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            beam_meta<=0; beam_sync<=0; sync_valid<=0;
        end else begin
            beam_meta<=beams; beam_sync<=beam_meta;
            sync_valid<={sync_valid[0],1'b1};
        end
    end
    // Per-line consecutive-sample filters. Seed from the actual synchronized
    // inputs, not reset zeros: both idle HIGH and idle LOW boot correctly.
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            filtered<=0; filter_initialized<=0;
            for(i=0;i<2;i=i+1) filter_count[i]<=0;
        end else if(sync_valid[1]) begin
            if(!filter_initialized) begin
                filtered<=beam_sync; filter_initialized<=1;
            end else for(i=0;i<2;i=i+1) begin
                if(beam_sync[i]==filtered[i]) filter_count[i]<=0;
                else if(filter_count[i]==F-1) begin
                    filtered[i]<=beam_sync[i]; filter_count[i]<=0;
                end else filter_count[i]<=filter_count[i]+1'b1;
            end
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            ready<=0; idle_level<=0; startup_count<=0;
            previous_blocked<=0; pair_age<=0; clear_age<=0; first_b<=0; state<=CLEAR;
            trigger<=0; reverse<=0; velocity<=160; gap_ms<=8;
        end else begin
            trigger<=0; // exactly one clk pulse per completed gesture
            previous_blocked<=blocked;
            if(!ready) begin
                state<=CLEAR; pair_age<=0; clear_age<=0;
                // Both synchronized lines must remain stable for S clocks;
                // even a rejected short glitch restarts startup qualification.
                if(!filter_initialized || beam_sync!=filtered) startup_count<=0;
                else if(startup_count==S-1) begin
                    idle_level<=filtered; ready<=1;
                end else startup_count<=startup_count+1'b1;
            end else if(suppress) begin
                // Test mode cancels the entire gesture, including pending pair.
                // Exit requires both filtered lines idle before rearming.
                state<=CLEAR; pair_age<=0; clear_age<=0;
            end else case(state)
                CLEAR: begin
                    // A block that arrived on the last suppressed clock may
                    // still be in the CDC/filter pipeline. Drain first, then
                    // require both synchronized AND filtered inputs idle.
                    // Otherwise that old gesture could trigger after exit.
                    if(clear_age!=3) clear_age<=clear_age+1'b1;
                    else if(blocked==0 && beam_sync==idle_level) state<=ARMED;
                end
                RELEASE: if(blocked==0) state<=ARMED;
                ARMED: begin
                    if(rising_blocked==2'b11) begin
                        // Same-clock edges contain no direction information.
                        trigger<=1; reverse<=0; velocity<=180; gap_ms<=6;
                        state<=RELEASE;
                    end else if(rising_blocked!=0) begin
                        first_b<=rising_blocked[1]; pair_age<=0; state<=PAIR;
                    end
                end
                PAIR: begin
                    // pair_age+1 is the distance between filtered rising events.
                    // At exactly P clocks an opposite edge wins over timeout.
                    if((first_b && rising_blocked[0]) ||
                       (!first_b && rising_blocked[1])) begin
                        trigger<=1; reverse<=first_b; state<=RELEASE;
                        if(pair_age+1<=8*MS) begin velocity<=255; gap_ms<=2; end
                        else if(pair_age+1<=20*MS) begin velocity<=220; gap_ms<=4; end
                        else if(pair_age+1<=50*MS) begin velocity<=180; gap_ms<=6; end
                        else begin velocity<=140; gap_ms<=10; end
                    end else if(pair_age==P-1) begin
                        // Single-beam fallback: no measured direction/speed.
                        trigger<=1; reverse<=0; velocity<=160; gap_ms<=8;
                        state<=RELEASE;
                    end else pair_age<=pair_age+1'b1;
                end
                default: state<=CLEAR;
            endcase
        end
    end
endmodule
