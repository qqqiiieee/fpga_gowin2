`timescale 1ns/1ps
// Real synchronous custom-score RAM: held note crosses quarter read bubbles,
// then repeated note, genuine rest, new high-end pitch and natural completion.
module tb_guide_modes_custom;
    parameter integer RUN_MODE=1;
    localparam integer SPB=23437;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, restart=0, sample_tick=0, midi_note_on=0, write_en=0;
    reg [6:0] midi_note=0;
    reg [8:0] write_addr=0;
    reg [31:0] write_data=0, config_word=0;
    wire active, done, expected_valid, practice_hold;
    wire [6:0] expected_note;
    wire [5:0] step_index;
    wire [11:0] roll_tick;
    wire [31:0] demo_gate, demo_retrigger;
    integer checks=0, onsets=0, bubbles=0, rest_cycles=0, accepted_events=0;
    integer q, duration_cycles=0;
    reg [5:0] last_accepted=63;
    reg [31:0] word;
    wire score_ready=guide.custom_word_ready;
    guide_play_modes modes(.clk(clk),.rst_n(rst_n),.mode(RUN_MODE[1:0]),
        .running(active && !done),.suspended(1'b0),.restart(restart),
        .score_ready(score_ready),.expected_note(expected_note),.expected_valid(expected_valid),
        .step_index(step_index),.midi_note_on(midi_note_on),.midi_note(midi_note),
        .practice_hold(practice_hold),.demo_gate(demo_gate),.demo_retrigger(demo_retrigger),
        .demo_velocity());
    piano_roll_guide #(.CUSTOM_SCORE_ENABLE(1)) guide(
        .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),.pause(practice_hold),.song_id(2'd3),
        .ui_start(1'b0),.ui_toggle(1'b0),.ui_restart(restart),.roll_tick(roll_tick),
        .active(active),.done(done),.step_index(step_index),
        .expected_note(expected_note),.expected_valid(expected_valid),
        .custom_write_clk(clk),.custom_write_en(write_en),.custom_write_addr(write_addr),
        .custom_write_data(write_data),.custom_config(config_word));
    task check;
        input condition;
        input [8*130-1:0] message;
        begin
            checks=checks+1;
            if(condition!==1) $fatal(1,"CUSTOM_MODES_FAIL mode=%0d tick=%0d step=%0d: %0s",
                                     RUN_MODE,roll_tick,step_index,message);
        end
    endtask
    task tick;
        begin @(posedge clk); #1; @(negedge clk); end
    endtask
    always @(posedge clk) if(rst_n && sample_tick) begin
        if(|demo_retrigger) onsets=onsets+1;
        if(!score_ready) bubbles=bubbles+1;
        if(score_ready && roll_tick>=176 && roll_tick<192) begin
            rest_cycles=rest_cycles+1;
            check(demo_gate==0 && !practice_hold,"real quarter rest stays silent and advances");
        end
        if(RUN_MODE==1 && roll_tick>129 && roll_tick<160) begin
            check(demo_gate==32'h00080000,"held C4 remains gated through quarter/RAM bubble");
            check(demo_retrigger==0,"held C4 is not retriggered at quarter 9");
        end
        if(RUN_MODE==2 && score_ready && expected_valid && step_index==last_accepted)
            check(!practice_hold,"already accepted custom note never re-waits after RAM read");
    end
    initial begin
        tick; rst_n=1; tick;
        // Initialize the whole addressable active bank, including tail padding.
        for(q=0;q<256;q=q+1) begin
            word=0;
            case(q)
                8: word=60 | (1<<13) | (1<<14);
                9: word=60 | (1<<13);
                10: word=60 | (1<<7) | (1<<13) | (1<<14);
                12: word=72 | (2<<7) | (1<<13) | (1<<14);
                13,14,15: word=72 | (2<<7) | (1<<13);
            endcase
            write_en=1; write_addr=q; write_data=word; tick;
        end
        write_en=0;
        config_word=(1<<30) | (3<<24) | (4<<18) | SPB;
        tick; tick; restart=1; tick; restart=0; tick; sample_tick=1;
        while(!done) begin
            tick;
            if(RUN_MODE==2 && score_ready && expected_valid && practice_hold) begin
                check(step_index!=last_accepted,"one fresh NoteOn per custom step only");
                // Wait for identity capture and a clean low event before firing.
                tick; tick;
                midi_note=expected_note; midi_note_on=1; tick; midi_note_on=0;
                check(!practice_hold,"custom correct NoteOn releases current step");
                last_accepted=step_index; accepted_events=accepted_events+1;
            end
            duration_cycles=duration_cycles+1;
            check(duration_cycles<SPB*5,"custom duration bounded");
        end
        tick;
        check(roll_tick==256 && demo_gate==0 && demo_retrigger==0,"custom end silent at exact score end");
        check(bubbles>=15 && rest_cycles>5000,"actual RAM transitions and rest exercised");
        if(RUN_MODE==1) check(onsets==3,"exactly three custom onsets including adjacent C4 repetition");
        else check(accepted_events==3 && onsets==0,"three practice events, no synthetic notes");
        $display("GUIDE_MODES_CUSTOM_PASS mode=%0d checks=%0d onsets=%0d accepts=%0d bubbles=%0d",
                 RUN_MODE,checks,onsets,accepted_events,bubbles); $finish;
    end
    initial begin #3000000; $fatal(1,"custom watchdog"); end
endmodule
