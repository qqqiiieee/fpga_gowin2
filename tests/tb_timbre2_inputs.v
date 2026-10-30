`timescale 1ns/1ps
// 直接验证真实instrument_inputs生产实例确实传入TIMBRE_COUNT=2。
// 只加速扫描周期，保留生产消抖、模式参数、事件接线与实体输入路径。
module tb_timbre2_inputs;
    reg clk=0,rst_n=0;
    always #5 clk=~clk;
    reg [15:0] pressed=0;
    wire [3:0] rows,selected,event_timbre;
    reg [3:0] cols;
    wire [15:0] keys;
    wire note_on,note_off;
    wire [6:0] note;
    wire [7:0] velocity;
    tri1 scl,sda;
    integer row,checks=0,ons=0,offs=0;
    instrument_inputs dut(.clk(clk),.rst_n(rst_n),.matrix_rows(rows),.matrix_cols(cols),
        .adc_scl(scl),.adc_sda(sda),.uart_rx(1'b1),.uart_tx(),
        .synth_overrun(1'b0),.suppress_controls(1'b0),
        .note_on(note_on),.note_off(note_off),.note(note),.velocity(velocity),
        .timbre(event_timbre),.key_state(keys),.selected_timbre(selected));
    defparam dut.u_keypad.ROW_CYCLES=12;
    always @(*)begin
        cols=4'hf;
        for(row=0;row<4;row=row+1)if(rows[row]===1'b0)cols=cols&~pressed[row*4+:4];
    end
    always @(posedge clk)begin
        #1;
        if(rst_n)begin
            if(selected!==0 && selected!==1)$fatal(1,"TIMBRE2_INPUTS selection out of range");
            if(note_on || note_off)begin
                if(note!==60 || velocity!==160 || event_timbre!==selected)
                    $fatal(1,"TIMBRE2_INPUTS wrong production note event");
            end
            if(note_on)ons=ons+1;
            if(note_off)offs=offs+1;
        end
    end
    task drive;
        input [15:0] mask;
        input [3:0] expected;
        begin
            @(negedge clk);pressed=mask;
            repeat(260)@(negedge clk);
            #2;checks=checks+1;
            if(keys!==mask || selected!==expected)
                $fatal(1,"TIMBRE2_INPUTS keys=%h expected=%h selected=%0d expected=%0d",keys,mask,selected,expected);
        end
    endtask
    integer i,expected;
    initial begin
        if(dut.u_keypad.TIMBRE_COUNT!=2)$fatal(1,"TIMBRE2_INPUTS production parameter must be 2");
        repeat(4)@(negedge clk);rst_n=1;drive(0,0);expected=0;
        for(i=0;i<8;i=i+1)begin
            drive(i<4?16'h1000:16'h2000,expected);
            expected=expected^1;drive(0,expected);
            drive(1,expected);drive(0,expected);
        end
        if(ons!=8 || offs!=8)$fatal(1,"TIMBRE2_INPUTS lost note events or selector emitted notes");
        $display("TIMBRE2_INPUTS_TEST_PASS checks=%0d releases=8 note_on=%0d note_off=%0d",checks,ons,offs);
        $finish;
    end
    initial begin #1000000;$fatal(1,"TIMBRE2_INPUTS timeout");end
endmodule
