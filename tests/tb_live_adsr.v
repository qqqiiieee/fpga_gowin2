`timescale 1ns/1ps
// 真正93.75kHz帧预算：每帧288拍，第260拍必须发布，禁止缩短调度来通过测试。
// CASE=0 ADSR；1 FSR；2 test32冻结oracle逐拍miter；3 默认16音色兼容；
// 4 有符号PCM端点；5 非DUAL_PROFILE不响应FSR。所有oracle只读且不改写。
module tb_live_adsr;
    parameter CASE=0;
    parameter PHASE_RAM=1;
    parameter BOUNDARY_POSITIVE=0;
    parameter WAVE="src/timbre_dual.hex";
    parameter OLD_WAVE="src/timbre_soft.hex";
    localparam TBITS=(CASE==3 || CASE==5)?4:1;
    localparam DUAL=(TBITS==1);
    localparam COMPACT=(CASE==4)?0:DUAL;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=1,fs_tick=0,test_mode=0;
    reg [31:0] gate=0,retrigger=0,pulse=0;
    reg [223:0] notes=0;
    reg [255:0] velocities=0;
    reg [32*TBITS-1:0] timbres=0;
    wire [127:0] old_timbres;
    reg signed [8:0] pitch=0;
    reg [7:0] a=0,d=0,s=255,r=0,pressure=0;
    wire [15:0] pcm,default_pcm,old_pcm;
    wire done,default_done,old_done,over,default_over,old_over;
    wire [31:0] busy,audible,default_busy,default_audible,old_busy,old_audible;
    genvar g;
    generate for(g=0;g<32;g=g+1) begin:map_old
        if(DUAL) assign old_timbres[g*4+:4]=timbres[g]?4'd7:4'd1;
        else assign old_timbres[g*4+:4]=timbres[g*TBITS+:TBITS];
    end endgenerate
    wavetable_synth #(.LIVE_ADSR_ENABLE(1),.PHASE_RAM(PHASE_RAM),
        .TIMBRE_BITS(TBITS),.NUM_TIMBRES(1<<TBITS),.DUAL_PROFILE(DUAL),
        .COMPACT_ROM(COMPACT),.FILE(WAVE),.PACKED_FILE("src/timbre_dual_half.hex")) dut(
        .clk(clk),.rst_n(rst_n),.fs_tick(fs_tick),.test_mode(test_mode),.gate(gate),.retrigger(retrigger),
        .note_bus(notes),.vel_bus(velocities),.timbre_bus(timbres),.pitch(pitch),
        .sample(pcm),.frame_done(done),.overrun(over),.voice_busy(busy),.voice_audible(audible),
        .attack_ctrl(a),.decay_ctrl(d),.sustain_ctrl(s),.release_ctrl(r),.damping(pressure));
    // 故意不覆盖LIVE_ADSR_ENABLE，检查默认参数，且新增输入确实连接并持续变化。
    wavetable_synth #(.PHASE_RAM(PHASE_RAM),.TIMBRE_BITS(TBITS),.NUM_TIMBRES(1<<TBITS),
        .DUAL_PROFILE(DUAL),.COMPACT_ROM(COMPACT),.FILE(WAVE),
        .PACKED_FILE("src/timbre_dual_half.hex")) default_dut(
        .clk(clk),.rst_n(rst_n),.fs_tick(fs_tick),.test_mode(test_mode),.gate(gate),.retrigger(retrigger),
        .note_bus(notes),.vel_bus(velocities),.timbre_bus(timbres),.pitch(pitch),
        .sample(default_pcm),.frame_done(default_done),.overrun(default_over),
        .voice_busy(default_busy),.voice_audible(default_audible),
        .attack_ctrl(a),.decay_ctrl(d),.sustain_ctrl(s),.release_ctrl(r),.damping(pressure));
    v016_wavetable_synth_reference #(.FILE(OLD_WAVE)) oracle(
        .clk(clk),.rst_n(rst_n),.fs_tick(fs_tick),.test_mode(test_mode),.gate(gate),.retrigger(retrigger),
        .note_bus(notes),.vel_bus(velocities),.timbre_bus(old_timbres),.pitch(pitch),
        .sample(old_pcm),.frame_done(old_done),.overrun(old_over),.voice_busy(old_busy),.voice_audible(old_audible));

    integer frames=0,clocks=0,negative=0,positive=0,arithmetic_checks=0;
    integer c,v,f,k,attack_fast,attack_slow,release_fast,release_slow;
    integer decay_fast,decay_slow,damp_medium,damp_strong,n,consumed;
    integer expected_amplitude,expected_velocity;
    reg check_amplitude;
    reg [19:0] previous_level;
    reg [63:0] frequency_numerator;
    reg [23:0] expected_increment;
    reg [7:0] saved_a,saved_d,saved_s,saved_r,saved_pressure;
    reg scramble=0;

    task compare_outputs;
        begin
            if({default_pcm,default_done,default_over,default_busy,default_audible} !==
               {old_pcm,old_done,old_over,old_busy,old_audible})
                $fatal(1,"DEFAULT oracle mismatch frame=%0d cycle=%0d PCM=%h/%h",frames,c,default_pcm,old_pcm);
            if((^{pcm,done,over,busy,audible,default_pcm,default_done,default_over})===1'bx)
                $fatal(1,"uninitialised state reached public outputs frame=%0d cycle=%0d",frames,c);
            if(CASE==2 && {pcm,done,over,busy,audible} !== {old_pcm,old_done,old_over,old_busy,old_audible})
                $fatal(1,"TEST32 control pollution frame=%0d cycle=%0d PCM=%h/%h",frames,c,pcm,old_pcm);
        end
    endtask

    task reset_duts;
        begin
            fs_tick=0;retrigger=0;pulse=0;gate=0;
            #2;rst_n=0;#1;
            compare_outputs;
            if({pcm,done,over,busy,audible}!==0 || dut.live_envelope_ram.valid!==0)
                $fatal(1,"asynchronous reset/valid mask");
            // 不清RAM、不force包络；旧小数必须靠valid掩码失效。
            repeat(2) @(negedge clk);
            rst_n=1;
        end
    endtask

    task frame;
        begin
            saved_a=a;saved_d=d;saved_s=s;saved_r=r;saved_pressure=pressure;
            for(c=0;c<288;c=c+1) begin
                fs_tick=(c==0);retrigger=(c==0)?pulse:0;
                // 消费前一拍/当拍/后一拍的一clk复触发都必须保留历史行为。
                if(CASE==2 && f>=512 && f<608 && c==8*((f-512)%32)+(f-512)/32)
                    retrigger[(f-512)%32]=1;
                if(scramble && c>0) begin
                    a=c+frames;d=255-c;s=c*7;r=c*13;pressure=c*29;
                end
                if(dut.running && dut.slot==0 && !fs_tick) begin
                    consumed=dut.voice_index;
                    if(dut.current_phase!==oracle.phases[consumed] ||
                       default_dut.current_phase!==oracle.phases[consumed])
                        $fatal(1,"independent per-voice phase/prefetch frame=%0d voice=%0d",frames,consumed);
                    if(CASE==2) begin
                        frequency_numerator=(400+97*consumed);
                        frequency_numerator=frequency_numerator*16777216+46875;
                        expected_increment=frequency_numerator/93750;
                        if(dut.selected_increment!==expected_increment)
                            $fatal(1,"TEST32 frequency changed by notes/pitch/control voice=%0d",consumed);
                    end
                end
                check_amplitude=dut.v2;
                // 独立的32位有符号计算，专门防止-32768*255被当成无符号/16位溢出。
                expected_amplitude=$signed(dut.interp2);
                expected_velocity=dut.env2;
                expected_amplitude=(expected_amplitude*expected_velocity)>>>8;
                @(posedge clk);#1;clocks=clocks+1;
                compare_outputs;
                if(check_amplitude) begin
                    if($signed(dut.sample3)!==expected_amplitude)
                        $fatal(1,"signed amplitude boundary got=%0d expected=%0d",$signed(dut.sample3),expected_amplitude);
                    arithmetic_checks=arithmetic_checks+1;
                end
                if(done!==(c==260) || default_done!==(c==260) || over!==0)
                    $fatal(1,"8 cycles/voice or 288-clock budget frame=%0d cycle=%0d",frames,c);
                if(dut.attack_frame!==saved_a || dut.decay_frame!==saved_d || dut.sustain_frame!==saved_s ||
                   dut.release_frame!==saved_r || dut.damping_frame!==saved_pressure)
                    $fatal(1,"controls were not frozen together at fs_tick frame=%0d cycle=%0d",frames,c);
                if(done) begin
                    if($signed(pcm)<0) negative=negative+1;
                    if($signed(pcm)>0) positive=positive+1;
                    for(k=0;k<32;k=k+1) begin
                        if({default_dut.envelopes[k],default_dut.states[k],default_dut.subdivisions[k],default_dut.previous_notes[k]} !==
                           {oracle.envelopes[k],oracle.states[k],oracle.subdivisions[k],oracle.previous_notes[k]})
                            $fatal(1,"DEFAULT state oracle mismatch voice=%0d",k);
                        if(CASE==2 && {dut.envelopes[k],dut.states[k],dut.subdivisions[k],dut.previous_notes[k]} !==
                           {oracle.envelopes[k],oracle.states[k],oracle.subdivisions[k],oracle.previous_notes[k]})
                            $fatal(1,"TEST32 envelope/subdivision changed voice=%0d",k);
                    end
                end
                @(negedge clk);
            end
            pulse=0;retrigger=0;fs_tick=0;frames=frames+1;
        end
    endtask

    task start_note;
        begin
            gate[0]=1;pulse[0]=1;frame;
            if(dut.envelopes[0]!==0 || dut.states[0]!==1)
                $fatal(1,"real NoteOn did not reset only its envelope");
        end
    endtask

    task measure_attack;
        input [7:0] control;
        output integer count;
        begin
            a=control;s=255;pressure=0;start_note;
            count=0;
            while(dut.states[0]==1 && count<5000) begin frame;count=count+1;end
            if(dut.envelopes[0]!==255 || dut.states[0]!==2)
                $fatal(1,"attack did not reach/clamp maximum velocity ctrl=%0d",control);
            frame;
            if(dut.states[0]!==3 || dut.envelopes[0]!==255) $fatal(1,"full sustain");
        end
    endtask

    task measure_release;
        input [7:0] control;
        output integer count;
        begin
            r=control;gate[0]=0;frame;
            if(dut.states[0]!==4) $fatal(1,"NoteOff must enter Release");
            count=0;
            while(busy[0] && count<5000) begin frame;count=count+1;end
            if(busy[0] || audible[0] || dut.envelopes[0]!==0)
                $fatal(1,"release failed to reach exact zero ctrl=%0d",control);
        end
    endtask

    task measure_decay;
        input [7:0] control;
        output integer count;
        begin
            d=control;s=64;count=0;
            while({dut.envelopes[0],dut.live_envelope_ram.ram[0]}!=20'h40000 && count<5000)
                begin frame;count=count+1;end
            if({dut.envelopes[0],dut.live_envelope_ram.ram[0]}!==20'h40000 || dut.states[0]!==3)
                $fatal(1,"decay sustain target control=%0d envelope=%0d",control,dut.envelopes[0]);
        end
    endtask

    task pressure_to_silence;
        input [7:0] control;
        output integer count;
        begin
            pressure=0;a=0;s=255;r=255;start_note;
            repeat(20) frame;
            if(dut.envelopes[0]!==255) $fatal(1,"new NoteOn after prior mute");
            pressure=control;count=0;previous_level=20'hff000;
            while(busy[0] && count<2500) begin
                frame;count=count+1;
                if({dut.envelopes[0],dut.live_envelope_ram.ram[0]}>=previous_level)
                    $fatal(1,"sustained damping not applied every frame ctrl=%0d",control);
                previous_level={dut.envelopes[0],dut.live_envelope_ram.ram[0]};
                if(dut.envelopes[1]!==255 || dut.states[1]!==3)
                    $fatal(1,"FSR2 contaminated flute id0");
            end
            if(busy[0] || audible[0] || dut.states[0]!==0)
                $fatal(1,"damping did not mute held plucked note");
            repeat(32) frame;
            pressure=0;
            // 门控始终为1；压力松开、S变化都不能凭空复触发已制音的音符。
            for(n=0;n<64;n=n+1) begin
                s=n[0]?255:0;frame;
                if(busy[0] || audible[0] || dut.envelopes[0]!==0 || dut.states[0]!==0)
                    $fatal(1,"muted note resurrected on damping release/sustain edit");
            end
        end
    endtask

    initial begin
        @(negedge clk);
        if(default_dut.LIVE_ADSR_ENABLE!==0) $fatal(1,"default LIVE_ADSR_ENABLE changed");
        for(v=0;v<32;v=v+1) begin
            notes[v*7+:7]=40+v;velocities[v*8+:8]=255;
        end
        notes[0+:7]=69;
        test_mode=(CASE==2);reset_duts;
        if(CASE==0) begin
            measure_attack(0,attack_fast);measure_release(0,release_fast);
            measure_attack(64,attack_slow);measure_release(64,release_slow);
            // 这四个数由已注明的全幅Q8.12码/帧直接计算，不通过DUT函数生成期望。
            if(attack_fast!=17 || attack_slow!=264 || release_fast!=17 || release_slow!=264)
                $fatal(1,"ADSR time range A=%0d/%0d R=%0d/%0d",attack_fast,attack_slow,release_fast,release_slow);
            measure_attack(0,n);measure_decay(0,decay_fast);
            measure_attack(0,n);measure_decay(64,decay_slow);
            if(decay_fast!=13 || decay_slow!=198)
                $fatal(1,"decay time range D=%0d/%0d",decay_fast,decay_slow);
            s=192;a=0;repeat(16) frame;
            if(dut.envelopes[0]!==192) $fatal(1,"live sustain increase while held");
            s=0;d=0;repeat(16) frame;
            if(dut.envelopes[0]!==0 || audible[0]) $fatal(1,"sustain0 is not silent");
            s=255;repeat(20) frame;
            if(dut.envelopes[0]!==255) $fatal(1,"sustain255 must equal velocity");
            // 已在Sustain中的音符调D，以及已在Release中的音符调R，都要本帧生效。
            d=128;s=0;repeat(16) frame;
            if(dut.envelopes[0]<253) $fatal(1,"slow decay precondition");
            d=0;repeat(20) frame;
            if(dut.envelopes[0]!==0) $fatal(1,"decay edit ignored while held");
            s=255;repeat(20) frame;
            r=128;gate[0]=0;frame;repeat(16) frame;
            if(dut.envelopes[0]<253 || dut.states[0]!==4) $fatal(1,"slow release precondition");
            r=0;repeat(20) frame;
            if(busy[0] || audible[0]) $fatal(1,"release edit ignored after NoteOff");
            a=128;start_note;repeat(16) frame;
            if(dut.envelopes[0]>1) $fatal(1,"slow attack precondition");
            a=0;repeat(20) frame;
            if(dut.envelopes[0]!==255) $fatal(1,"attack control only took effect at NoteOn");
            // 同时活跃的0/31声部有独立包络；重触发0不能重置31。
            reset_duts;a=64;s=255;gate=32'h80000001;frame;repeat(16) frame;
            previous_level={dut.envelopes[31],dut.live_envelope_ram.ram[31]};
            pulse=1;frame;
            if(dut.envelopes[0]!==0 || {dut.envelopes[31],dut.live_envelope_ram.ram[31]}<=previous_level)
                $fatal(1,"voices share envelope state");
            for(v=1;v<31;v=v+1) if(dut.envelopes[v]!==0 || dut.states[v]!==0)
                $fatal(1,"inactive voice acquired another voice's envelope");
            reset_duts;a=0;s=255;velocities[0+:8]=0;start_note;repeat(4) frame;
            if(dut.envelopes[0]!==0 || pcm!==0) $fatal(1,"velocity0 generated nonzero audio");
            velocities[0+:8]=1;start_note;repeat(4) frame;
            if(dut.envelopes[0]!==1) $fatal(1,"velocity1 overflow/clamp");
            velocities[0+:8]=128;s=128;start_note;repeat(20) frame;
            if(dut.envelopes[0]!==64) $fatal(1,"Sustain is not scaled by velocity");
            // RAM已被写入非零小数后复位，首帧/所有空闲路仍必须为零。
            reset_duts;frame;
            if({busy,audible,pcm}!==0) $fatal(1,"stale RAM fraction leaked after reset");
            if(negative<10 || positive<10) $fatal(1,"signed musical PCM not exercised");
        end else if(CASE==1) begin
            a=0;s=255;r=255;timbres[0+:TBITS]=1;gate=3;frame;repeat(20) frame;
            pressure_to_silence(64,damp_medium);
            pressure_to_silence(255,damp_strong);
            if(damp_medium!=2037 || damp_strong!=512 || damp_strong*3>=damp_medium)
                $fatal(1,"damping strength/time count=%0d/%0d",damp_medium,damp_strong);
            pressure=0;s=255;start_note;repeat(20) frame;
            if(dut.envelopes[0]!==255 || !audible[0]) $fatal(1,"fresh NoteOn blocked by previous damping");
            pressure=255;frame;
            previous_level={dut.envelopes[0],dut.live_envelope_ram.ram[0]};
            pressure=0;
            repeat(32) begin
                frame;
                if({dut.envelopes[0],dut.live_envelope_ram.ram[0]}>previous_level || dut.states[0]!==4)
                    $fatal(1,"partially damped held note resumed Attack/Sustain on pressure release");
                previous_level={dut.envelopes[0],dut.live_envelope_ram.ram[0]};
            end
            // 连续压住FSR时，新NoteOn也要有正常起音，再被持续阻尼衰减；不能
            // 把“防止松压重触发”实现成永久阻止所有新NoteOn。
            pressure=255;start_note;frame;
            if(!audible[0] || dut.states[0]!==1)
                $fatal(1,"sustained pressure swallowed fresh fast-attack NoteOn");
            n=0;
            while(busy[0] && n<600) begin frame;n=n+1;end
            if(busy[0] || audible[0]) $fatal(1,"new note escaped sustained damping");
            pressure=0;repeat(32) frame;
            if(busy[0] || audible[0]) $fatal(1,"fresh damped note resurrected on release");
        end else if(CASE==2 || CASE==3) begin
            scramble=1;
            for(f=0;f<640;f=f+1) begin
                gate=32'hffffffff;
                for(v=0;v<32;v=v+1) begin
                    timbres[v*TBITS+:TBITS]=(CASE==2)?v%2:(v+f/16)%16;
                    velocities[v*8+:8]=(CASE==2)?192:(v*11+f)%256;
                    notes[v*7+:7]=(CASE==2)?40+v:(v*7+f/8)%128;
                end
                if(CASE==3) test_mode=f[6];
                pitch=f[0]?-9'sd256:9'sd255;
                a=f;d=255-f;s=f*17;r=f*37;pressure=f*53;
                if(f>=608) pulse=32'hffffffff;
                frame;
            end
            // 重触发前先恢复非零包络，再真正NoteOff，覆盖旧包络的完整释放尾音。
            pulse=0;velocities={32{8'd192}};repeat(512) frame;
            gate=0;repeat(3200) frame;
            if(CASE==2 && {pcm,busy,audible}!==0) $fatal(1,"TEST32 historical release tail not silent");
            if(CASE==2 && (negative<50 || positive<50)) $fatal(1,"TEST32 signed PCM coverage");
        end else if(CASE==4) begin
            a=0;s=255;gate=1;repeat(32) frame;
            if($signed(pcm)!==(BOUNDARY_POSITIVE?8159:-8160))
                $fatal(1,"one-voice full-velocity signed endpoint PCM=%0d",$signed(pcm));
            gate=32'hffffffff;repeat(32) frame;
            if($signed(pcm)!==(BOUNDARY_POSITIVE?32767:-32767) ||
               $signed(dut.accumulator)!==(BOUNDARY_POSITIVE?1044448:-1044480))
                $fatal(1,"32-voice signed sum/clipping endpoint PCM=%0d sum=%0d",$signed(pcm),$signed(dut.accumulator));
        end else if(CASE==5) begin
            a=0;s=255;r=255;gate=1;timbres[0+:TBITS]=1;repeat(32) frame;
            pressure=255;repeat(600) frame;
            if(dut.envelopes[0]!==255 || dut.states[0]!==3)
                $fatal(1,"FSR must require DUAL_PROFILE and id1 together");
        end else $fatal(1,"unknown test CASE");
        if(arithmetic_checks<100) $fatal(1,"amplitude scoreboard never active");
        $display("LIVE_ADSR_TEST_PASS case=%0d phase_ram=%0d frames=%0d clocks=%0d signed_checks=%0d positive=%0d negative=%0d A=%0d/%0d D=%0d/%0d R=%0d/%0d damping=%0d/%0d",
            CASE,PHASE_RAM,frames,clocks,arithmetic_checks,positive,negative,attack_fast,attack_slow,decay_fast,decay_slow,release_fast,release_slow,damp_medium,damp_strong);
        $finish;
    end
    initial begin #100000000;$fatal(1,"LIVE_ADSR_TEST_FAIL watchdog");end
endmodule
