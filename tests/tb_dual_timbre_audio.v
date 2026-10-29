`timescale 1ns/1ps
// 端到端：冻结V016完整音频层和V017共用所有控制，仅在入口映射音色编号。
// LOWPASS=0/1分别执行；REDUCED=0额外确认默认16音色兼容分支。
// PT8211除逐拍引脚比较外，按BCLK上升沿独立重组左右16位字，与整帧装载前PCM核对。
module tb_dual_timbre_audio;
    parameter LOWPASS=1;
    parameter REDUCED=1;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,note_on=0,note_off=0,hit0=0,hit1=0;
    reg [6:0] note=69;
    reg [7:0] velocity=192,volume=160;
    reg [3:0] timbre=0;
    wire [3:0] old_timbre=REDUCED?((timbre==1)?4'd7:4'd1):timbre;
    reg signed [8:0] pitch=0;
    reg zero_test=0,filter_enable=1,owned=0,test_mode=0,clear_audio=0,ready=1;
    reg [31:0] test_mask=0;
    reg [8:0] gain=256;
    wire bck0,ws0,din0,over0,tick0,bck1,ws1,din1,over1,tick1;
    wire [15:0] pcm0,pcm1;
    wire signed [8:0] pitch0,pitch1;
    wire [31:0] busy0,busy1,audible0,audible1;
    instrument_audio #(.TRANSITION_INPUT_ENABLE(1),.REDUCED_TIMBRES(REDUCED),.LOWPASS_ENABLE(LOWPASS)) candidate(
        .clk(clk),.rst_n(rst_n),.note_on(note_on),.note_off(note_off),.note(note),.velocity(velocity),
        .timbre(timbre),.slider_volume(volume),.slider_pitch(pitch),.hit0(hit0),.hit1(hit1),
        .velocity0(8'd190),.velocity1(8'd170),.digital_zero_test(zero_test),.filter_enable(filter_enable),
        .test_owned(owned),.test_mode(test_mode),.test_clear(clear_audio),.normal_input_ready(ready),
        .test_gate_mask(test_mask),.test_master_gain(gain),.hp_bck(bck0),.hp_ws(ws0),.hp_din(din0),
        .overrun(over0),.monitor_tick(tick0),.monitor_pcm(pcm0),.monitor_pitch(pitch0),
        .monitor_busy(busy0),.monitor_test_busy(audible0));
    v016_instrument_audio_reference #(.TRANSITION_INPUT_ENABLE(1),.LOWPASS_ENABLE(LOWPASS)) baseline(
        .clk(clk),.rst_n(rst_n),.note_on(note_on),.note_off(note_off),.note(note),.velocity(velocity),
        .timbre(old_timbre),.slider_volume(volume),.slider_pitch(pitch),.hit0(hit0),.hit1(hit1),
        .velocity0(8'd190),.velocity1(8'd170),.digital_zero_test(zero_test),.filter_enable(filter_enable),
        .test_owned(owned),.test_mode(test_mode),.test_clear(clear_audio),.normal_input_ready(ready),
        .test_gate_mask(test_mask),.test_master_gain(gain),.hp_bck(bck1),.hp_ws(ws1),.hp_din(din1),
        .overrun(over1),.monitor_tick(tick1),.monitor_pcm(pcm1),.monitor_pitch(pitch1),
        .monitor_busy(busy1),.monitor_test_busy(audible1));

    integer clocks=0,frames=0,normal_nonzero=0,test_nonzero=0,tail_frames=0,quiet_frames=0;
    integer serial_words=0,serial_nonzero=0,partial_frames=0,all32_music=0,all32_test=0;
    integer note_events=0,off_events=0,drum_events=0,local_resets=0,global_resets=0,owned_ready=0;
    integer f,v,serial_phase=0,tick_distance=0,frame_age=0;
    reg [15:0] tones_seen=0,serial_shift=0,expected_loaded=0;
    reg [2:0] gain_seen=0,pitch_seen=0;
    reg [1:0] filter_seen=0;
    reg previous_bck=0,had_tick=0,frame_valid=0,tick_before;
    reg [15:0] pcm_before;

    always @(posedge clk) begin
        tick_before=tick0;pcm_before=pcm0;
        #1;
        clocks=clocks+1;
        if({bck0,ws0,din0,over0,tick0,pcm0,pitch0,busy0,audible0} !==
           {bck1,ws1,din1,over1,tick1,pcm1,pitch1,busy1,audible1} ||
           (^{bck0,ws0,din0,over0,tick0,pcm0,pitch0,busy0,audible0})===1'bx)
            $fatal(1,"DUAL_TIMBRE_AUDIO ports lp=%0d reduced=%0d clock=%0d f=%0d PCM=%h/%h",LOWPASS,REDUCED,clocks,f,pcm0,pcm1);
        // 各级都比较，避免末端静音、音量0或数字零掩盖上游出错。
        if({candidate.mixed,candidate.frame_done,candidate.kick_sample,candidate.snare_sample,
            candidate.mix_sample,candidate.dc_sample,candidate.clean_sample,candidate.sample,
            candidate.quiet,candidate.gate,candidate.retrigger,candidate.note_bus,candidate.vel_bus,
            candidate.voice_busy,candidate.voice_audible} !==
           {baseline.mixed,baseline.frame_done,baseline.kick_sample,baseline.snare_sample,
            baseline.mix_sample,baseline.dc_sample,baseline.clean_sample,baseline.sample,
            baseline.quiet,baseline.gate,baseline.retrigger,baseline.note_bus,baseline.vel_bus,
            baseline.voice_busy,baseline.voice_audible})
            $fatal(1,"DUAL_TIMBRE_AUDIO processing stage lp=%0d reduced=%0d clock=%0d f=%0d",LOWPASS,REDUCED,clocks,f);
        if(!rst_n) begin
            serial_phase=0;serial_shift=0;expected_loaded=0;previous_bck=0;
            tick_distance=0;had_tick=0;frame_age=0;frame_valid=0;
        end else begin
            if(over0!==0) $fatal(1,"DUAL_TIMBRE_AUDIO unexpected overrun");
            tick_distance=tick_distance+1;
            if(tick_before) begin
                if(had_tick && tick_distance!=288) $fatal(1,"DUAL_TIMBRE_AUDIO fs_tick period=%0d",tick_distance);
                tick_distance=0;had_tick=1;expected_loaded=pcm_before;frames=frames+1;
                frame_age=0;frame_valid=!clear_audio;
                if(pcm_before!=0) begin
                    if(test_mode) test_nonzero=test_nonzero+1;else normal_nonzero=normal_nonzero+1;
                    if(f>=992 && f<5408) tail_frames=tail_frames+1;
                end
                if(candidate.quiet) quiet_frames=quiet_frames+1;
                if(test_mode && test_mask!=0 && test_mask!=32'hffffffff) partial_frames=partial_frames+1;
                if(candidate.voice_audible==32'hffffffff) begin
                    if(test_mode) all32_test=all32_test+1;else all32_music=all32_music+1;
                end
                if(owned && ready) owned_ready=owned_ready+1;
                if(test_mode) case(gain)
                    0:gain_seen[0]=1;128:gain_seen[1]=1;256:gain_seen[2]=1;
                endcase
                if(pitch0<0) pitch_seen[0]=1;
                if(pitch0>0) pitch_seen[1]=1;
                if(pitch0==0) pitch_seen[2]=1;
                filter_seen[filter_enable]=1;
            end else frame_age=frame_age+1;
            if(clear_audio) frame_valid=0;
            if(frame_valid && candidate.frame_done!==(frame_age==260))
                $fatal(1,"DUAL_TIMBRE_AUDIO independent frame_done latency age=%0d",frame_age);
            if(zero_test && pcm0!==0) $fatal(1,"DUAL_TIMBRE_AUDIO digital zero not zero");
            if(test_mode && gain==0 && pcm0!==0) $fatal(1,"DUAL_TIMBRE_AUDIO test mute not zero");
            if(!previous_bck && bck0) begin
                if(ws0!==(serial_phase>=16)) $fatal(1,"DUAL_TIMBRE_AUDIO PT8211 WS phase=%0d",serial_phase);
                serial_shift={serial_shift[14:0],din0};
                if(serial_phase%16==15) begin
                    if(serial_shift!==expected_loaded)
                        $fatal(1,"DUAL_TIMBRE_AUDIO PT8211 decoded word channel=%0d expected=%h got=%h",serial_phase/16,expected_loaded,serial_shift);
                    serial_words=serial_words+1;
                    if(serial_shift!=0) serial_nonzero=serial_nonzero+1;
                end
                serial_phase=(serial_phase+1)%32;
            end
            previous_bck=bck0;
            if(candidate.frame_done) for(v=0;v<32;v=v+1) begin
                if({candidate.synth.phases[v],candidate.synth.envelopes[v],candidate.synth.states[v]} !==
                   {baseline.synth.phases[v],baseline.synth.envelopes[v],baseline.synth.states[v]})
                    $fatal(1,"DUAL_TIMBRE_AUDIO synth state voice=%0d f=%0d",v,f);
                if(REDUCED && !test_mode && candidate.voice_busy[v])
                    if(baseline.timbre_bus[v*4+:4] !== (candidate.timbre_bus[v]?4'd7:4'd1))
                        $fatal(1,"DUAL_TIMBRE_AUDIO allocation timbre mapping voice=%0d",v);
            end
        end
    end

    // 每个事件只保持一个clk，不能把note_on保持整帧误当一次按键。
    task event_pulse;
        input on_value,off_value,kick_value,snare_value;
        begin
            note_on=on_value;note_off=off_value;hit0=kick_value;hit1=snare_value;
            if(on_value) begin note_events=note_events+1;tones_seen[timbre]=1;end
            if(off_value) off_events=off_events+1;
            if(kick_value || snare_value) drum_events=drum_events+1;
            @(negedge clk);note_on=0;note_off=0;hit0=0;hit1=0;
        end
    endtask
    task one_frame;
        begin
            @(negedge clk);while(!tick0) @(negedge clk);
            @(negedge clk);
        end
    endtask
    task clear_local;
        begin
            clear_audio=1;local_resets=local_resets+1;
            repeat(2) @(negedge clk);clear_audio=0;
        end
    endtask
    task reset_global;
        begin
            #2;rst_n=0;#2;
            if({bck0,ws0,din0,over0,pcm0,busy0,audible0}!==0)
                $fatal(1,"DUAL_TIMBRE_AUDIO asynchronous global reset");
            global_resets=global_resets+1;
            repeat(3) @(negedge clk);rst_n=1;
        end
    endtask

    initial begin
        @(negedge clk);reset_global;
        if(candidate.synth.NUM_VOICES!=32 || candidate.synth.COMPACT_ROM!=1 ||
           candidate.synth.TIMBRE_BITS!=(REDUCED?1:4) || candidate.synth.NUM_TIMBRES!=(REDUCED?2:16) ||
           candidate.synth.DUAL_PROFILE!=REDUCED || $bits(candidate.timbre_bus)!=(REDUCED?32:128))
            $fatal(1,"DUAL_TIMBRE_AUDIO parameter/width checks");
        for(f=0;f<6912;f=f+1) begin
            volume=(f/200)%3==0?255:((f/200)%3==1?127:0);
            pitch=(f/160)%3==0?-9'sd256:((f/160)%3==1?9'sd255:9'sd0);
            filter_enable=(f/100)%2;zero_test=(f>=500 && f<520);
            if(f<32) begin
                note=48+f;velocity=128+f*3;timbre=f%2;event_pulse(1,0,0,0);
            end
            // 覆盖全部16种外部4位编码，包括2..15应回退到长笛的无效编号。
            if(f>=640 && f<656) begin
                note=80+f-640;velocity=255;timbre=f-640;event_pulse(1,0,0,0);
            end
            if(f>=800 && f<832) begin
                note=48+f-800;velocity=160+(f%32);timbre=f%2;event_pulse(1,0,0,0);
            end
            if(f>=864 && f<992) begin note=f-864;event_pulse(0,1,0,0);end
            if(f==150 || f==200 || f==300) event_pulse(0,0,f!=200,f!=150);
            if(f==5407 && (busy0!==0 || pcm0!==0 || candidate.quiet!==1))
                $fatal(1,"DUAL_TIMBRE_AUDIO complete tail/quiet not reached busy=%h PCM=%h",busy0,pcm0);
            if(f==5408) begin owned=1;ready=0;test_mode=1;test_mask=32'hffffffff;clear_local;end
            if(f==5800) test_mask=32'hfffdffff;
            if(f==5900) test_mask=32'hffffffff;
            if(f>=5980 && f<6048) gain=(f%3==0)?0:((f%3==1)?128:256);
            if(f==6048) begin test_mode=0;test_mask=0;gain=0;ready=1;clear_local;end
            if(f==6049) begin note=69;velocity=255;timbre=1;event_pulse(1,0,0,0);end
            if(f>=6048 && f<6176) gain=(f-6048)*2;
            if(f==6176) begin owned=0;gain=256;end
            if(f==6496) begin note=69;event_pulse(0,1,0,0);end
            // 释放中途复位，再重新发音，确认串行器和音频状态同时重新启动。
            if(f==6700) reset_global;
            if(f==6701) begin note=72;timbre=0;velocity=192;event_pulse(1,0,0,0);end
            one_frame;
        end
        if(frames<6910 || tones_seen!==16'hffff || normal_nonzero<500 || test_nonzero<300 ||
           tail_frames<500 || quiet_frames<100 || serial_words<13800 || serial_nonzero<1000 ||
           partial_frames<90 || all32_music<300 || all32_test<300 || gain_seen!==7 ||
           pitch_seen!==7 || filter_seen!==3 || local_resets!=2 || global_resets!=2 || owned_ready<120 ||
           note_events!=82 || off_events!=129 || drum_events!=3)
            $fatal(1,"DUAL_TIMBRE_AUDIO coverage lp=%0d reduced=%0d frames=%0d normal=%0d test=%0d tail=%0d quiet=%0d serial=%0d all32=%0d/%0d events=%0d/%0d/%0d gains=%b pitches=%b ownedready=%0d",
                LOWPASS,REDUCED,frames,normal_nonzero,test_nonzero,tail_frames,quiet_frames,serial_words,all32_music,all32_test,note_events,off_events,drum_events,gain_seen,pitch_seen,owned_ready);
        $display("DUAL_TIMBRE_AUDIO_TEST_PASS lowpass=%0d reduced=%0d clocks=%0d frames=%0d normal_nonzero=%0d test_nonzero=%0d tail=%0d quiet=%0d serial_words=%0d serial_nonzero=%0d all32_music=%0d all32_test=%0d partial=%0d note_events=%0d off_events=%0d drum_events=%0d local_resets=%0d global_resets=%0d external_timbres=16 gain_codes=3",
            LOWPASS,REDUCED,clocks,frames,normal_nonzero,test_nonzero,tail_frames,quiet_frames,serial_words,serial_nonzero,all32_music,all32_test,partial_frames,note_events,off_events,drum_events,local_resets,global_resets);
        $finish;
    end
    initial begin #30000000;$fatal(1,"DUAL_TIMBRE_AUDIO_TEST_FAIL watchdog");end
endmodule
