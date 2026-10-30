`timescale 1ns/1ps
// 串行端到端驱动与外部握手记分板。所有测试仅驱动引脚，不 force UART 内部。
// 记分板只记录 event_valid && event_ready；同时检查背压下字段保持稳定。
module midi_test_driver #(
    parameter integer CLK_HZ=1000000,
    parameter integer ACTIVE_SENSE_MS=350,
    parameter integer MIDI_CHANNEL=0,
    parameter integer DRUM_CHANNEL=9
);
    localparam integer BIT_CYCLES=(CLK_HZ+15625)/31250;
    localparam integer SENSE_CYCLES=(CLK_HZ/1000)*ACTIVE_SENSE_MS;
    localparam real HALF_NS=500000000.0/CLK_HZ;
    reg clk=0, rst_n=0, rx=1, suppress=0, ready=1;
    always #(HALF_NS) clk=~clk;
    wire valid,on_event,off_event;
    wire [6:0] note;
    wire [7:0] velocity;
    wire [127:0] held;
    wire program_valid,timbre,volume_valid,bend_valid;
    wire [7:0] volume;
    wire signed [8:0] bend;
    wire [6:0] modulation;
    wire hit0,hit1,panic,framing_error,overflow;
    wire [7:0] drum0,drum1,received;
    midi_keyboard #(.CLK_HZ(CLK_HZ),.ACTIVE_SENSE_MS(ACTIVE_SENSE_MS),
        .MIDI_CHANNEL(MIDI_CHANNEL),.DRUM_CHANNEL(DRUM_CHANNEL)) dut (
        .clk(clk),.rst_n(rst_n),.rx(rx),.suppress(suppress),.event_ready(ready),
        .event_valid(valid),.event_on(on_event),.event_off(off_event),
        .event_note(note),.event_velocity(velocity),.held_notes(held),
        .program_valid(program_valid),.timbre_select(timbre),
        .volume_valid(volume_valid),.volume(volume),.bend_valid(bend_valid),.bend(bend),
        .modulation(modulation),.hit0(hit0),.hit1(hit1),
        .drum_velocity0(drum0),.drum_velocity1(drum1),.panic(panic),
        .framing_error(framing_error),.overflow(overflow),.received_count(received)
    );
    reg log_on [0:8191];
    reg [6:0] log_note [0:8191];
    reg [7:0] log_velocity [0:8191];
    integer count=0, checked=0, panics=0, programs=0, volumes=0, bends=0;
    integer kicks=0,snares=0,stall_checks=0,cycles=0,last_panic_cycle=0;
    reg [7:0] last_kick=0,last_snare=0;
    reg [127:0] gates=0;
    reg stalled=0,old_suppress=0;
    reg [15:0] stable_value=0;
    always @(posedge clk) begin
        if (!rst_n) begin
            count=0; checked=0; panics=0; programs=0; volumes=0; bends=0;
            kicks=0; snares=0; gates=0; stalled=0; old_suppress=0;
            last_kick=0; last_snare=0; cycles=0; last_panic_cycle=0; stall_checks=0;
        end else begin
            cycles=cycles+1;
            if (stalled && !panic && suppress==old_suppress) begin
                if (!valid || {on_event,note,velocity}!==stable_value)
                    $fatal(1,"MIDI event changed while stalled cycle=%0d",cycles);
                stall_checks=stall_checks+1;
            end
            if (valid && (on_event===off_event)) $fatal(1,"MIDI invalid event flags");
            // suppress入口在本沿撤销旧队列；不能把已撤销的旧valid继续作为
            // 下一拍的保持义务。其余背压周期仍逐拍验证完整字段。
            stalled=valid && !ready && !panic && !(suppress && !old_suppress);
            stable_value={on_event,note,velocity};
            old_suppress=suppress;
            if (valid && ready) begin
                if (count>=8192) $fatal(1,"MIDI test log overflow");
                log_on[count]=on_event; log_note[count]=note; log_velocity[count]=velocity;
                count=count+1;
                if (on_event) gates[note]=1; else gates[note]=0;
            end
            if (panic) begin panics=panics+1; gates=0; last_panic_cycle=cycles; end
            if (program_valid) programs=programs+1;
            if (volume_valid) volumes=volumes+1;
            if (bend_valid) bends=bends+1;
            if (hit0) begin kicks=kicks+1; last_kick=drum0; end
            if (hit1) begin snares=snares+1; last_snare=drum1; end
            // 控制和鼓为单拍；鼓力度与命中同拍，下一拍必须回零。
            if (!hit0 && drum0!=0) $fatal(1,"MIDI kick velocity persisted");
            if (!hit1 && drum1!=0) $fatal(1,"MIDI snare velocity persisted");
        end
    end
    task tick;
        input integer n;
        begin repeat(n) @(negedge clk); end
    endtask
    task reset;
        begin
            @(negedge clk); rst_n=0; rx=1; suppress=0; ready=1;
            tick(8); rst_n=1; tick(BIT_CYCLES*2);
        end
    endtask
    task serial;
        input [7:0] value;
        input integer delta;
        input integer good_stop;
        integer j;
        begin
            rx=0; tick(BIT_CYCLES+delta);
            for (j=0;j<8;j=j+1) begin rx=value[j]; tick(BIT_CYCLES+delta); end
            rx=(good_stop!=0); tick(BIT_CYCLES+delta);
        end
    endtask
    task tx;
        input [7:0] value;
        begin serial(value,0,1); end
    endtask
    task msg;
        input [7:0] status;
        input [6:0] a,b;
        begin tx(status); tx({1'b0,a}); tx({1'b0,b}); end
    endtask
    task expect_event;
        input integer want_on;
        input integer want_note,want_velocity;
        integer wait_cycles;
        begin
            wait_cycles=0;
            while (count<=checked && wait_cycles<1024) begin tick(1); wait_cycles=wait_cycles+1; end
            if (count<=checked) $fatal(1,"MIDI missing event on=%0d note=%0d",want_on,want_note);
            if (log_on[checked]!==want_on[0] || log_note[checked]!==want_note[6:0] ||
                log_velocity[checked]!==want_velocity[7:0])
                $fatal(1,"MIDI event[%0d] got=%0d,%0d,%0d expected=%0d,%0d,%0d",
                    checked,log_on[checked],log_note[checked],log_velocity[checked],
                    want_on,want_note,want_velocity);
            checked=checked+1;
        end
    endtask
    task quiet;
        begin
            tick(180);
            if (count!=checked) $fatal(1,"MIDI unexpected events got=%0d checked=%0d",count,checked);
        end
    endtask
endmodule
