`timescale 1ns/1ps
// 直接检查真实同步 ROM 读口，不以 Python 重建成功替代 RTL 的地址/符号验证。
// 此 bench 只驱动 ROM 地址；音乐/包络回归在另一个 bench 中完全由正常输入推进。
module tb_dual_timbre_rom;
    reg clk=0; always #5 clk=~clk;
    reg [10:0] address=0;
    reg [13:0] old_address=0;
    reg [15:0] source16[0:16383],source2[0:2047];
    wire [15:0] unused0,unused1,unused2;
    wavetable_synth #(.TIMBRE_BITS(1),.NUM_TIMBRES(2),.DUAL_PROFILE(1),
        .COMPACT_ROM(1),.FILE("src/timbre_dual.hex"),.PACKED_FILE("src/timbre_dual_half.hex")) packed_dut(
        .clk(clk),.rst_n(1'b0),.fs_tick(1'b0),.test_mode(1'b0),.gate(32'd0),.retrigger(32'd0),
        .note_bus(224'd0),.vel_bus(256'd0),.timbre_bus(32'd0),.pitch(9'sd0),.sample(unused0));
    wavetable_synth #(.TIMBRE_BITS(1),.NUM_TIMBRES(2),.DUAL_PROFILE(1),
        .COMPACT_ROM(0),.FILE("src/timbre_dual.hex")) full_dut(
        .clk(clk),.rst_n(1'b0),.fs_tick(1'b0),.test_mode(1'b0),.gate(32'd0),.retrigger(32'd0),
        .note_bus(224'd0),.vel_bus(256'd0),.timbre_bus(32'd0),.pitch(9'sd0),.sample(unused1));
    v016_wavetable_synth_reference reference_engine(
        .clk(clk),.rst_n(1'b0),.fs_tick(1'b0),.test_mode(1'b0),.gate(32'd0),.retrigger(32'd0),
        .note_bus(224'd0),.vel_bus(256'd0),.timbre_bus(128'd0),.pitch(9'sd0),.sample(unused2));
    integer bank,idx,checked=0,negative=0,positive=0,endpoints=0;
    initial begin
        $readmemh("src/timbre_soft.hex",source16);
        $readmemh("src/timbre_dual.hex",source2);
        force packed_dut.rom_address=address;
        force full_dut.rom_address=address;
        force reference_engine.rom_address=old_address;
        for(bank=0;bank<2;bank=bank+1) for(idx=0;idx<1024;idx=idx+1) begin
            @(negedge clk);
            address=bank*1024+idx;old_address=(bank?7:1)*1024+idx;
            @(posedge clk);#1;
            if(packed_dut.rom_q!==source16[old_address] || full_dut.rom_q!==source16[old_address] ||
               reference_engine.rom_q!==source16[old_address] || source2[address]!==source16[old_address] ||
               (^packed_dut.rom_q)===1'bx)
                $fatal(1,"DUAL_TIMBRE_ROM mismatch bank=%0d idx=%0d packed=%h full=%h old=%h",
                    bank,idx,packed_dut.rom_q,full_dut.rom_q,source16[old_address]);
            checked=checked+1;
            if($signed(packed_dut.rom_q)>0) positive=positive+1;
            if($signed(packed_dut.rom_q)<0) negative=negative+1;
            if(idx==0 || idx==511 || idx==512 || idx==513 || idx==1023) endpoints=endpoints+1;
        end
        if(checked!=2048 || positive<500 || negative<500 || endpoints!=10)
            $fatal(1,"DUAL_TIMBRE_ROM coverage");
        $display("DUAL_TIMBRE_ROM_TEST_PASS points=%0d positive=%0d negative=%0d endpoints=%0d",checked,positive,negative,endpoints);
        $finish;
    end
    initial begin #100000;$fatal(1,"DUAL_TIMBRE_ROM_TEST_FAIL watchdog");end
endmodule
