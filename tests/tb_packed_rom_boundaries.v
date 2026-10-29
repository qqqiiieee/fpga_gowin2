`timescale 1ns/1ps
// Every timbre contributes audible PCM at 0, 511->512, 512->513 and 1023->0,
// with interpolation fractions 0 and 255. Only phases are seeded in both DUTs.
module tb_packed_rom_boundaries;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,fs_tick=0;
    reg [223:0] notes=0;
    reg [127:0] timbres=0;
    wire [15:0] old_sample,new_sample;
    wire old_done,new_done,old_overrun,new_overrun;
    wire [31:0] old_busy,new_busy,old_audible,new_audible;
    wavetable_synth_v015_reference baseline(
        .clk(clk),.rst_n(rst_n),.fs_tick(fs_tick),.test_mode(1'b0),
        .gate(32'hffffffff),.retrigger(32'd0),.note_bus(notes),.vel_bus({32{8'hff}}),
        .timbre_bus(timbres),.pitch(-9'sd256),.sample(old_sample),.frame_done(old_done),
        .overrun(old_overrun),.voice_busy(old_busy),.voice_audible(old_audible));
    wavetable_synth #(.COMPACT_ROM(1)) candidate(
        .clk(clk),.rst_n(rst_n),.fs_tick(fs_tick),.test_mode(1'b0),
        .gate(32'hffffffff),.retrigger(32'd0),.note_bus(notes),.vel_bus({32{8'hff}}),
        .timbre_bus(timbres),.pitch(-9'sd256),.sample(new_sample),.frame_done(new_done),
        .overrun(new_overrun),.voice_busy(new_busy),.voice_audible(new_audible));
    reg [7:0] boundary_masks[0:15];
    integer clocks=0,frames=0,directed_reads=0;
    integer f,c,v,t,bank,index_value,fraction_value,selected_voice;
    reg [23:0] seed;
    task one_frame;
        input integer boundary_case;
        begin
            for(c=0;c<288;c=c+1) begin
                fs_tick=(c==0);
                if(boundary_case>=0 && c>=1 && c<=249 && (c-1)%8==0) begin
                    selected_voice=(c-1)/8;
                    if(baseline.phases[selected_voice][23:14]!==index_value ||
                       baseline.phases[selected_voice][13:6]!==fraction_value ||
                       baseline.envelopes[selected_voice]==0)
                        $fatal(1,"PACKED_ROM_BOUNDARIES invalid directed phase/env voice=%0d",selected_voice);
                    boundary_masks[selected_voice%16][boundary_case]=1;
                    directed_reads=directed_reads+1;
                end
                @(posedge clk);#1;
                clocks=clocks+1;
                if({old_sample,old_done,old_overrun,old_busy,old_audible} !==
                   {new_sample,new_done,new_overrun,new_busy,new_audible} ||
                   (^old_sample)===1'bx || old_done!==(c==260) || old_overrun!==0 ||
                   baseline.rom_q!==candidate.rom_q)
                    $fatal(1,"PACKED_ROM_BOUNDARIES mismatch frame=%0d cycle=%0d",frames,c);
                if(old_done) begin
                    for(v=0;v<32;v=v+1)
                        if(baseline.phases[v]!==candidate.phases[v] || baseline.envelopes[v]!==candidate.envelopes[v])
                            $fatal(1,"PACKED_ROM_BOUNDARIES state voice=%0d",v);
                end
                @(negedge clk);
            end
            frames=frames+1;
        end
    endtask
    initial begin
        for(v=0;v<32;v=v+1) begin notes[v*7+:7]=69;timbres[v*4+:4]=v%16;end
        for(bank=0;bank<16;bank=bank+1) boundary_masks[bank]=0;
        repeat(4) @(negedge clk);rst_n=1;
        for(f=0;f<300;f=f+1) one_frame(-1);
        if(old_audible!==32'hffffffff) $fatal(1,"PACKED_ROM_BOUNDARIES warmup not audible");
        for(t=0;t<8;t=t+1) begin
            case(t/2)
                0:index_value=0;
                1:index_value=511;
                2:index_value=512;
                default:index_value=1023;
            endcase
            fraction_value=t[0]?255:0;
            seed=(index_value<<14)|(fraction_value<<6)|(t[0]?63:0);
            for(v=0;v<32;v=v+1) begin baseline.phases[v]=seed;candidate.phases[v]=seed;end
            one_frame(t);
        end
        for(bank=0;bank<16;bank=bank+1) if(boundary_masks[bank]!==8'hff)
            $fatal(1,"PACKED_ROM_BOUNDARIES missing timbre=%0d mask=%h",bank,boundary_masks[bank]);
        $display("PACKED_ROM_BOUNDARIES_TEST_PASS clocks=%0d frames=%0d timbres=16 boundary_cases_per_timbre=8 active_reads=%0d",
            clocks,frames,directed_reads);
        $finish;
    end
    initial begin #2000000;$fatal(1,"PACKED_ROM_BOUNDARIES_TEST_FAIL watchdog");end
endmodule
