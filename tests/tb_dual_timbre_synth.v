`timescale 1ns/1ps
// V017 半表、V017 完整表、冻结 V016 三方逐拍比较。
// 新0->旧1，新1->旧7。除边界用例仅给三方相位相同初值之外，不改任何包络、
// 流水线、PCM、ROM 或累加器。所有重触发均为真正的一拍输入脉冲。
module tb_dual_timbre_synth;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,fs_tick=0,test_mode=0;
    reg [31:0] gate=0,retrigger=0,timbres=0;
    reg [223:0] notes=0;
    reg [255:0] velocities=0;
    wire [127:0] old_timbres;
    reg signed [8:0] pitch=0;
    genvar g;
    generate for(g=0;g<32;g=g+1) begin:map_ids
        assign old_timbres[g*4+:4]=timbres[g]?4'd7:4'd1;
    end endgenerate
    wire [15:0] pcm0,pcm1,pcm2;
    wire done0,done1,done2,over0,over1,over2;
    wire [31:0] busy0,busy1,busy2,audible0,audible1,audible2;
    v016_wavetable_synth_reference baseline(
        .clk(clk),.rst_n(rst_n),.fs_tick(fs_tick),.test_mode(test_mode),.gate(gate),.retrigger(retrigger),
        .note_bus(notes),.vel_bus(velocities),.timbre_bus(old_timbres),.pitch(pitch),
        .sample(pcm0),.frame_done(done0),.overrun(over0),.voice_busy(busy0),.voice_audible(audible0));
    wavetable_synth #(.TIMBRE_BITS(1),.NUM_TIMBRES(2),.DUAL_PROFILE(1),.COMPACT_ROM(1),
        .FILE("src/timbre_dual.hex"),.PACKED_FILE("src/timbre_dual_half.hex")) candidate(
        .clk(clk),.rst_n(rst_n),.fs_tick(fs_tick),.test_mode(test_mode),.gate(gate),.retrigger(retrigger),
        .note_bus(notes),.vel_bus(velocities),.timbre_bus(timbres),.pitch(pitch),
        .sample(pcm1),.frame_done(done1),.overrun(over1),.voice_busy(busy1),.voice_audible(audible1));
    wavetable_synth #(.TIMBRE_BITS(1),.NUM_TIMBRES(2),.DUAL_PROFILE(1),.COMPACT_ROM(0),
        .FILE("src/timbre_dual.hex")) full_candidate(
        .clk(clk),.rst_n(rst_n),.fs_tick(fs_tick),.test_mode(test_mode),.gate(gate),.retrigger(retrigger),
        .note_bus(notes),.vel_bus(velocities),.timbre_bus(timbres),.pitch(pitch),
        .sample(pcm2),.frame_done(done2),.overrun(over2),.voice_busy(busy2),.voice_audible(audible2));

    integer f,c,v,target,cut,clocks=0,frames=0,reset_checks=0,tail_frames=0;
    integer positive=0,negative=0,all32_music=0,all32_sine=0,mode_switches=0,snapshots=0;
    integer attack1=0,attack8=0,restarts=0,boundary_reads=0;
    reg [31:0] before_mask=0,on_mask=0,after_mask=0;
    reg [1:0] timbres_seen[0:31];
    reg [7:0] boundaries[0:1];
    reg [255:0] velocities_seen=0;
    reg [127:0] notes_seen=0;
    reg [4:0] adsr_seen=0;
    reg [2:0] pitches_seen=0;
    reg [31:0] expected_pending=0,frame_gate=0,frame_timbres=0;
    reg [223:0] frame_notes=0;
    reg [255:0] frame_velocities=0;
    reg frame_mode=0;
    integer consumed,expected_env,old_env,old_state,step_attack;
    reg is_restart;
    reg [23:0] seed;

    task compare_outputs;
        begin
            clocks=clocks+1;
            if({pcm0,done0,over0,busy0,audible0}!=={pcm1,done1,over1,busy1,audible1} ||
               {pcm0,done0,over0,busy0,audible0}!=={pcm2,done2,over2,busy2,audible2} ||
               (^{pcm0,done0,over0,busy0,audible0})===1'bx)
                $fatal(1,"DUAL_TIMBRE_SYNTH clock=%0d frame=%0d c=%0d PCM=%h/%h/%h busy=%h/%h",
                    clocks,f,c,pcm0,pcm1,pcm2,busy0,busy1);
            if(baseline.pending_triggers!==expected_pending || candidate.pending_triggers!==expected_pending ||
               full_candidate.pending_triggers!==expected_pending)
                $fatal(1,"DUAL_TIMBRE_SYNTH independent trigger scoreboard frame=%0d c=%0d",f,c);
        end
    endtask
    task compare_states;
        integer k;
        begin
            for(k=0;k<32;k=k+1) begin
                if({baseline.phases[k],baseline.envelopes[k],baseline.states[k],baseline.subdivisions[k],baseline.previous_notes[k]} !==
                   {candidate.phases[k],candidate.envelopes[k],candidate.states[k],candidate.subdivisions[k],candidate.previous_notes[k]} ||
                   {baseline.phases[k],baseline.envelopes[k],baseline.states[k],baseline.subdivisions[k],baseline.previous_notes[k]} !==
                   {full_candidate.phases[k],full_candidate.envelopes[k],full_candidate.states[k],full_candidate.subdivisions[k],full_candidate.previous_notes[k]})
                    $fatal(1,"DUAL_TIMBRE_SYNTH internal state frame=%0d voice=%0d",f,k);
                adsr_seen[baseline.states[k]]=1;
            end
        end
    endtask
    // 每次上升沿之前更新独立 pending 模型：先消费，后 OR 当拍事件。
    // 此顺序专门覆盖恰好落在该声部 slot0 上的 retrigger，必须保留到下一帧。
    task step;
        input tick;
        input [31:0] pulse;
        begin
            fs_tick=tick;retrigger=pulse;consumed=-1;expected_env=-1;is_restart=0;
            if(baseline.running && baseline.slot==0 && !tick) begin
                consumed=baseline.voice_index;
                old_env=baseline.envelopes[consumed];old_state=baseline.states[consumed];
                is_restart=frame_gate[consumed] && (!baseline.previous_gates[consumed] ||
                    frame_notes[consumed*7+:7]!=baseline.previous_notes[consumed] || expected_pending[consumed]);
                step_attack=frame_timbres[consumed]?8:1;
                if(is_restart) expected_env=0;
                else if(frame_gate[consumed] && old_state==1) begin
                    expected_env=old_env+step_attack;
                    if(expected_env>=frame_velocities[consumed*8+:8]) expected_env=frame_velocities[consumed*8+:8];
                end
                if(frame_gate[consumed]) begin
                    timbres_seen[consumed][frame_timbres[consumed]]=1;
                    velocities_seen[frame_velocities[consumed*8+:8]]=1;
                    notes_seen[frame_notes[consumed*7+:7]]=1;
                end
            end
            // pending寄存器的消费使能独立于fs_tick。过载时即使新tick中断了
            // 本拍的包络更新，旧running/slot0仍会清掉该声部的旧pending。
            // 因此不能把它误写成上方“!tick时才更新声部状态”的条件。
            if(baseline.running && baseline.slot==0) expected_pending[baseline.voice_index]=0;
            expected_pending=expected_pending|pulse;
            if(tick) begin
                frame_gate=gate;frame_timbres=timbres;frame_notes=notes;frame_velocities=velocities;frame_mode=test_mode;
            end
            @(posedge clk);#1;
            compare_outputs;
            if(consumed>=0 && expected_env>=0) begin
                if(candidate.envelopes[consumed]!==expected_env[7:0])
                    $fatal(1,"DUAL_TIMBRE_SYNTH independent ADSR voice=%0d expected=%0d got=%0d",consumed,expected_env,candidate.envelopes[consumed]);
                if(is_restart) begin
                    restarts=restarts+1;
                    if(candidate.states[consumed]!==1) $fatal(1,"DUAL_TIMBRE_SYNTH restart did not enter ATTACK");
                end else if(expected_env==old_env+step_attack) begin
                    if(step_attack==1) attack1=attack1+1;else attack8=attack8+1;
                end
            end
            if(done0) begin
                frames=frames+1;compare_states;
                if($signed(pcm0)>0) positive=positive+1;
                if($signed(pcm0)<0) negative=negative+1;
                if(f>=2304 && f<6656 && pcm0!=0) tail_frames=tail_frames+1;
                if(audible0==32'hffffffff) begin
                    if(frame_mode) all32_sine=all32_sine+1;else all32_music=all32_music+1;
                end
            end
            @(negedge clk);
        end
    endtask
    // 在主时钟边沿之间真正拉低复位，检查异步清零，而非仅等待同步采样后相等。
    task async_reset;
        begin
            fs_tick=0;retrigger=0;#2;rst_n=0;expected_pending=0;#1;
            compare_outputs;compare_states;
            if({pcm0,done0,over0,busy0,audible0}!==0 || baseline.previous_gates!==0)
                $fatal(1,"DUAL_TIMBRE_SYNTH asynchronous reset output");
            for(v=0;v<32;v=v+1)
                if({baseline.phases[v],baseline.envelopes[v],baseline.states[v],baseline.subdivisions[v],baseline.previous_notes[v]}!==0)
                    $fatal(1,"DUAL_TIMBRE_SYNTH asynchronous reset state voice=%0d",v);
            reset_checks=reset_checks+1;
            repeat(2) @(negedge clk);rst_n=1;
        end
    endtask

    initial begin
        for(v=0;v<32;v=v+1) timbres_seen[v]=0;
        boundaries[0]=0;boundaries[1]=0;
        @(negedge clk);async_reset;
        if($bits(candidate.timbres_frame)!=32 || candidate.TIMBRE_BITS!=1 || candidate.NUM_TIMBRES!=2 ||
           candidate.DUAL_PROFILE!=1 || candidate.COMPACT_ROM!=1)
            $fatal(1,"DUAL_TIMBRE_SYNTH production parameters/width");
        for(f=0;f<6912;f=f+1) begin
            gate=(f<2304 || f>=6656)?32'hffffffff:0;
            test_mode=(f>=1280 && f<1792) || (f>=6656);
            if(f>=1792 && f<1856) begin test_mode=f[0];mode_switches=mode_switches+1;end
            for(v=0;v<32;v=v+1) begin
                if(f<512) begin
                    notes[v*7+:7]=(f+v*7)%128;
                    velocities[v*8+:8]=(f+v*13)%256;
                    timbres[v]=(f/256+v)%2;
                end else begin
                    notes[v*7+:7]=40+v;
                    velocities[v*8+:8]=192+v;
                    timbres[v]=v%2;
                end
            end
            case(f%3)
                0:begin pitch=-9'sd256;pitches_seen[0]=1;end
                1:begin pitch=9'sd255;pitches_seen[1]=1;end
                2:begin pitch=0;pitches_seen[2]=1;end
            endcase
            // 两音色分别在0、511->512、512->513、1023->0处，检查frac=0/255。
            // 预热128帧以上，确保这些边界样本实际经过非零包络和PCM乘加。
            if(f>=640 && f<648) begin
                case((f-640)/2)
                    0:target=0;1:target=511;2:target=512;3:target=1023;
                endcase
                seed=(target<<14)|((f%2?255:0)<<6)|(f%2?63:0);
                for(v=0;v<32;v=v+1) begin
                    if(baseline.envelopes[v]==0) $fatal(1,"DUAL_TIMBRE_SYNTH inactive boundary voice=%0d",v);
                    baseline.phases[v]=seed;candidate.phases[v]=seed;full_candidate.phases[v]=seed;
                    boundaries[timbres[v]][f-640]=1;boundary_reads=boundary_reads+1;
                end
            end
            for(c=0;c<288;c=c+1) begin
                retrigger=0;
                if(f>=768 && f<864) begin
                    target=(f-768)%32;
                    if(c==8*target+(f-768)/32) begin
                        retrigger[target]=1;
                        case((f-768)/32)
                            0:before_mask[target]=1;1:on_mask[target]=1;2:after_mask[target]=1;
                        endcase
                    end
                end
                // 帧中输入突变不能影响这一帧被冻结的门控、音符、力度、音色和测试选择。
                if(f>=1792 && f<1800 && c==100) begin
                    test_mode=~test_mode;gate=~gate;notes=~notes;velocities=~velocities;timbres=~timbres;pitch=~pitch;
                    snapshots=snapshots+1;
                end
                step(c==0,retrigger);
                if(done0!==(c==260) || over0!==0) $fatal(1,"DUAL_TIMBRE_SYNTH cadence frame=%0d c=%0d",f,c);
                if(candidate.gates_frame!==frame_gate || candidate.notes_frame!==frame_notes ||
                   candidate.velocities_frame!==frame_velocities || candidate.timbres_frame!==frame_timbres || candidate.test_frame!==frame_mode)
                    $fatal(1,"DUAL_TIMBRE_SYNTH frame snapshot frame=%0d c=%0d",f,c);
            end
            if(f==6655 && {pcm0,busy0,audible0}!==0) $fatal(1,"DUAL_TIMBRE_SYNTH release failed to reach silence");
        end
        for(v=0;v<32;v=v+1) if(timbres_seen[v]!==2'b11) $fatal(1,"DUAL_TIMBRE_SYNTH voice timbre coverage %0d",v);
        if(frames!=6912 || positive<500 || negative<500 || tail_frames<500 || attack1<100 || attack8<100 ||
           all32_music<500 || all32_sine<500 || before_mask!==32'hffffffff || on_mask!==32'hffffffff ||
           after_mask!==32'hffffffff || boundaries[0]!==8'hff || boundaries[1]!==8'hff ||
           velocities_seen!=={256{1'b1}} || notes_seen!=={128{1'b1}} || adsr_seen!==5'b11111 || pitches_seen!==7 || snapshots!=8)
            $fatal(1,"DUAL_TIMBRE_SYNTH coverage frames=%0d pos=%0d neg=%0d tail=%0d attacks=%0d/%0d all32=%0d/%0d ADSR=%b",
                frames,positive,negative,tail_frames,attack1,attack8,all32_music,all32_sine,adsr_seen);
        // 非法过密启动必须报overrun，且粘滞保持；不能只比较两侧始终为0。
        step(1,32'hffffffff);step(1,0);
        if(over0!==1) $fatal(1,"DUAL_TIMBRE_SYNTH overrun did not assert");
        repeat(288) step(0,0);
        if(over0!==1) $fatal(1,"DUAL_TIMBRE_SYNTH overrun not sticky");
        // 遍历整个32声部调度及4拍发布流水线的中断复位位置。
        for(cut=0;cut<264;cut=cut+1) begin
            async_reset;step(1,32'hffffffff);
            for(c=0;c<cut;c=c+1) step(0,0);
        end
        async_reset;
        $display("DUAL_TIMBRE_SYNTH_TEST_PASS clocks=%0d frames=%0d normal_frames=6912 positive=%0d negative=%0d tail=%0d attack1=%0d attack8=%0d restarts=%0d all32_music=%0d all32_sine=%0d boundary_reads=%0d mode_switches=%0d snapshots=%0d resets=%0d trigger_before=32 trigger_on=32 trigger_after=32 ADSR=%b notes=128 velocities=256",
            clocks,frames,positive,negative,tail_frames,attack1,attack8,restarts,all32_music,all32_sine,boundary_reads,mode_switches,snapshots,reset_checks,adsr_seen);
        $finish;
    end
    initial begin #30000000;$fatal(1,"DUAL_TIMBRE_SYNTH_TEST_FAIL watchdog");end
endmodule
