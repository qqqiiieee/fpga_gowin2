`timescale 1ns/1ps
// 显式二音色实例之外，保留默认参数的历史16音色功能，不允许新增参数改变旧调用。
module tb_dual_timbre_compat;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,tick=0,mode=0;
    reg [31:0] gate=32'hffffffff,trig=0;
    reg [223:0] notes=0;
    reg [255:0] vel=0;
    reg [127:0] timbres=0;
    reg signed [8:0] pitch=0;
    wire [15:0] a,b,d;
    wire da,db,dd,oa,ob,od;
    wire [31:0] ba,bb,bd,aa,ab,ad;
    v016_wavetable_synth_reference baseline(.clk(clk),.rst_n(rst_n),.fs_tick(tick),.test_mode(mode),
        .gate(gate),.retrigger(trig),.note_bus(notes),.vel_bus(vel),.timbre_bus(timbres),.pitch(pitch),
        .sample(a),.frame_done(da),.overrun(oa),.voice_busy(ba),.voice_audible(aa));
    wavetable_synth default_full(.clk(clk),.rst_n(rst_n),.fs_tick(tick),.test_mode(mode),
        .gate(gate),.retrigger(trig),.note_bus(notes),.vel_bus(vel),.timbre_bus(timbres),.pitch(pitch),
        .sample(b),.frame_done(db),.overrun(ob),.voice_busy(bb),.voice_audible(ab));
    wavetable_synth #(.COMPACT_ROM(1)) default_packed(.clk(clk),.rst_n(rst_n),.fs_tick(tick),.test_mode(mode),
        .gate(gate),.retrigger(trig),.note_bus(notes),.vel_bus(vel),.timbre_bus(timbres),.pitch(pitch),
        .sample(d),.frame_done(dd),.overrun(od),.voice_busy(bd),.voice_audible(ad));
    integer f,c,v,frames=0,clocks=0,nonzero=0;
    reg [15:0] seen=0;
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        if(default_full.TIMBRE_BITS!=4 || default_full.NUM_TIMBRES!=16 || default_full.DUAL_PROFILE!=0 || default_full.COMPACT_ROM!=0)
            $fatal(1,"DUAL_TIMBRE_COMPAT default parameters");
        for(f=0;f<768;f=f+1) begin
            mode=(f>=512);pitch=f%2?9'sd255:-9'sd256;
            for(v=0;v<32;v=v+1) begin
                notes[v*7+:7]=48+v;vel[v*8+:8]=192+v;timbres[v*4+:4]=(v+f/128)%16;
                seen[timbres[v*4+:4]]=1;
            end
            for(c=0;c<288;c=c+1) begin
                tick=(c==0);trig=(f%127==0 && c==121)?32'hffffffff:0;
                @(posedge clk);#1;clocks=clocks+1;
                if({a,da,oa,ba,aa}!=={b,db,ob,bb,ab} || {a,da,oa,ba,aa}!=={d,dd,od,bd,ad} ||
                   (^{a,da,oa,ba,aa})===1'bx || da!==(c==260) || oa!==0)
                    $fatal(1,"DUAL_TIMBRE_COMPAT frame=%0d cycle=%0d PCM=%h/%h/%h",f,c,a,b,d);
                if(da) begin frames=frames+1;if(a!=0) nonzero=nonzero+1;end
                @(negedge clk);
            end
        end
        if(frames!=768 || nonzero<500 || seen!==16'hffff) $fatal(1,"DUAL_TIMBRE_COMPAT coverage");
        $display("DUAL_TIMBRE_COMPAT_TEST_PASS clocks=%0d frames=%0d nonzero=%0d timbres=16 defaults_4_16_0 full_and_packed",clocks,frames,nonzero);
        $finish;
    end
    initial begin #3000000;$fatal(1,"DUAL_TIMBRE_COMPAT_TEST_FAIL watchdog");end
endmodule
