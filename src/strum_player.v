// Snapshot chord player, all ports synchronous to clk, rst_n asynchronous LOW.
// Event frame: valid + exactly one of on/off, 7-bit MIDI note, 8-bit velocity.
// Consumer accepts ONLY on valid && ready. Every field stays stable while stalled.
// Main must tag every accepted event source=2, timbre=1 (plucked); these tags are
// deliberately not output here. Main's test mode must clear source-2 voices AND
// gate event acceptance with !suppress: suppress cancels a stalled event outright.
// trigger is a one-clock command. held_notes[n]=1 means MIDI note n is held.
// Each command snapshots all 128 bits, direction, velocity and gap (milliseconds).
// Empty snapshot uses C4/E4/G4/C5. Direction selects the first MAX_NOTES notes
// (maximum six), so a larger chord keeps its lowest/highest six respectively.
// Later triggers preempt: finish any already-presented event, send an off for
// EACH accepted on, then play the latest pending snapshot. Pending depth is one;
// newer commands overwrite pending only, never the cleanup ledger.
module strum_player #(
    parameter CLK_HZ=27000000, parameter MAX_NOTES=6, parameter HOLD_MS=150
)(
    input clk, input rst_n, input trigger, input reverse,
    input [7:0] velocity, input [3:0] gap_ms,
    input [127:0] held_notes, input suppress, input event_ready,
    output reg event_valid, output reg event_on, output reg event_off,
    output reg [6:0] event_note, output reg [7:0] event_velocity,
    output reg busy
);
    function integer bits_for;
        input integer n;
        integer v;
        begin v=n-1; bits_for=0;
            while(v>0) begin bits_for=bits_for+1; v=v>>1; end
            if(bits_for<1) bits_for=1;
        end
    endfunction
    localparam LIMIT=(MAX_NOTES<1)?1:((MAX_NOTES>6)?6:MAX_NOTES);
    localparam MS=(CLK_HZ<1000)?1:((CLK_HZ+999)/1000);
    localparam HOLD_CYCLES=(HOLD_MS<1)?1:(MS*HOLD_MS);
    localparam MAX_GAP_CYCLES=15*MS;
    localparam MAX_TIME=(HOLD_CYCLES>MAX_GAP_CYCLES)?HOLD_CYCLES:MAX_GAP_CYCLES;
    localparam TW=bits_for(MAX_TIME+1), GW=bits_for(MAX_GAP_CYCLES+1);
    localparam NW=bits_for(LIMIT+1);
    localparam [127:0] DEFAULT_CHORD=(128'b1<<60)|(128'b1<<64)|
                                             (128'b1<<67)|(128'b1<<72);
    localparam IDLE=0, SCAN=1, PLAY=2, RELEASE=3;
    reg [1:0] state;
    reg pending_valid, pending_reverse;
    reg [127:0] pending_notes, scan_notes;
    reg [7:0] pending_velocity, play_velocity;
    reg [3:0] pending_gap;
    reg play_reverse;
    reg [6:0] scan_note;
    reg [6:0] notes [0:LIMIT-1];
    // note_count=selected, sent_count=accepted ons, off_index=accepted offs.
    // This bounded ledger survives all trigger replacements and backpressure.
    reg [NW-1:0] note_count, sent_count, off_index;
    // Production: 22 elapsed bits and 19 gap bits, rather than two 32-bit
    // counters. Widths follow parameters; saturation preserves long stalls.
    reg [TW-1:0] elapsed;
    reg [GW-1:0] play_gap_cycles;
    wire scan_last=play_reverse ? (scan_note==0) : (scan_note==127);
    integer i;
    always @(*) busy=(state!=IDLE) || pending_valid;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; pending_valid<=0; pending_reverse<=0;
            pending_notes<=0; pending_velocity<=0; pending_gap<=0;
            scan_notes<=0; scan_note<=0; play_reverse<=0; play_velocity<=0;
            note_count<=0; sent_count<=0; off_index<=0;
            elapsed<=0; play_gap_cycles<=1;
            event_valid<=0; event_on<=0; event_off<=0;
            event_note<=0; event_velocity<=0;
            for(i=0;i<LIMIT;i=i+1) notes[i]<=0;
        end else if(suppress) begin
            // Main clears sound in test mode, so no offs are required here.
            // Drop pending command, presented event and all ownership records.
            state<=IDLE; pending_valid<=0; note_count<=0; sent_count<=0;
            off_index<=0; elapsed<=0; event_valid<=0; event_on<=0;
            event_off<=0; event_note<=0; event_velocity<=0;
            pending_notes<=0; scan_notes<=0;
        end else begin
            if(trigger) begin
                pending_valid<=1;
                pending_notes<=(held_notes==0)?DEFAULT_CHORD:held_notes;
                pending_reverse<=reverse; pending_velocity<=velocity;
                pending_gap<=gap_ms;
            end
            // Elapsed clocks since the LAST ACCEPTED on. Saturate instead of
            // wrapping during indefinitely stalled events. HOLD is measured
            // from the final accepted on, never from the initial trigger.
            if(elapsed!={TW{1'b1}}) elapsed<=elapsed+1'b1;
            case(state)
                IDLE: if(pending_valid && !trigger) begin
                    scan_notes<=pending_notes; play_reverse<=pending_reverse;
                    scan_note<=pending_reverse?7'd127:7'd0;
                    play_velocity<=pending_velocity;
                    play_gap_cycles<=(pending_gap==0)?1:(pending_gap*MS);
                    note_count<=0; sent_count<=0; off_index<=0; elapsed<=0;
                    pending_valid<=0; state<=SCAN;
                end
                SCAN: begin
                    // One note-number examined per clk, at most 128 clocks.
                    // Scan completes before the first on: no scan latency is
                    // inserted between notes of the audible strum.
                    if(trigger || pending_valid) begin state<=RELEASE; off_index<=0; end
                    else begin
                        if(scan_notes[scan_note]) begin
                            notes[note_count]<=scan_note; note_count<=note_count+1'b1;
                        end
                        if(scan_last || (scan_notes[scan_note] && note_count==LIMIT-1))
                            state<=PLAY;
                        else scan_note<=play_reverse?(scan_note-1'b1):(scan_note+1'b1);
                    end
                end
                PLAY: begin
                    if(event_valid) begin
                        // A new trigger cannot retract a stalled note_on.
                        // Its eventual acceptance is added to the off ledger.
                        if(event_ready) begin
                            event_valid<=0; event_on<=0; event_off<=0;
                            sent_count<=sent_count+1'b1; elapsed<=0;
                            if(trigger || pending_valid) begin
                                state<=RELEASE; off_index<=0;
                            end
                        end
                    end else if(trigger || pending_valid) begin
                        state<=RELEASE; off_index<=0;
                    end else if(sent_count<note_count) begin
                        // Present one cycle before its earliest acceptance.
                        // With ready high, inter-on gap is exact for >=2 clocks;
                        // zero gap is clamped, one-slot transport takes >=2 clocks.
                        if(sent_count==0 || elapsed>=play_gap_cycles-2 || play_gap_cycles<2) begin
                            event_valid<=1; event_on<=1; event_off<=0;
                            event_note<=notes[sent_count]; event_velocity<=play_velocity;
                        end
                    end else if(elapsed>=HOLD_CYCLES-2 || HOLD_CYCLES<2) begin
                        // Present first off now, accepted after HOLD_CYCLES.
                        // Remaining offs follow in original playback order.
                        state<=RELEASE; off_index<=0;
                        if(sent_count!=0) begin
                            event_valid<=1; event_on<=0; event_off<=1;
                            event_note<=notes[0]; event_velocity<=0;
                        end
                    end
                end
                RELEASE: begin
                    if(event_valid) begin
                        if(event_ready) begin
                            event_valid<=0; event_on<=0; event_off<=0;
                            off_index<=off_index+1'b1;
                        end
                    end else if(off_index<sent_count) begin
                        event_valid<=1; event_on<=0; event_off<=1;
                        event_note<=notes[off_index]; event_velocity<=0;
                    end else begin
                        state<=IDLE; sent_count<=0; note_count<=0; off_index<=0;
                    end
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
