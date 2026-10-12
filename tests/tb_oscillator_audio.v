// 验证真实合成数据通路：32独立相位、音频帧期限、线性幅度与单路释放。
// 输出的文本PCM用于离线FFT；这是RTL仿真数据，不能代替实机录音。
module tb_oscillator_audio;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,note_on=0,note_off=0,owned=0,test_mode=0,clear_audio=0;
    reg [6:0] note=69;
    reg [31:0] mask=0;
    wire tick;wire [15:0] pcm;wire [31:0] busy,audible;
    wire overrun,bck,ws,din;
    instrument_audio dut(.clk(clk),.rst_n(rst_n),.note_on(note_on),.note_off(note_off),
        .note(note),.velocity(8'd160),.timbre(4'd0),.slider_volume(8'd160),.slider_pitch(9'sd0),
        .hit0(1'b0),.hit1(1'b0),.velocity0(8'd0),.velocity1(8'd0),
        .digital_zero_test(1'b0),.filter_enable(1'b1),.test_owned(owned),.test_mode(test_mode),
        .test_clear(clear_audio),.test_gate_mask(mask),.test_master_gain(9'd256),
        .hp_bck(bck),.hp_ws(ws),.hp_din(din),.overrun(overrun),
        .monitor_tick(tick),.monitor_pcm(pcm),.monitor_pitch(),.monitor_busy(busy),.monitor_test_busy(audible));
    reg [23:0] old_phase[0:31];
    integer frame_count=0,max_level=0,i,j,full_file,off_file,value,nonzero_normal=0;
    reg phase_check=0;
    function [23:0] step;
        input integer index;
        real increment;
        begin increment=(400.0+97.0*index)*16777216.0/93750.0;step=$rtoi(increment+0.5);end
    endfunction
    task frame;
        begin
            @(negedge clk);
            while(!tick)@(negedge clk);
            if(overrun)$fatal(1,"32路计算错过288clk帧期限");
            if((^pcm)===1'bx)$fatal(1,"PCM未定义");
            if(phase_check)for(i=0;i<32;i=i+1)begin
                if(dut.synth.phases[i]!==((old_phase[i]+step(i)) & 24'hffffff))
                    $fatal(1,"voice%0d independent increment wrong",i);
            end
            for(i=0;i<32;i=i+1)old_phase[i]=dut.synth.phases[i];
            frame_count=frame_count+1;
            value=$signed(pcm);
            if(value<0)value=-value;
            if(value>max_level)max_level=value;
            if(value>12288)$fatal(1,"test linear headroom violated: %0d",value);
        end
    endtask
    initial begin
        repeat(8)@(negedge clk);rst_n=1;
        owned=1;test_mode=1;mask=32'hffffffff;clear_audio=1;
        repeat(2)@(negedge clk);clear_audio=0;
        repeat(2000)frame;
        if(audible!==32'hffffffff)$fatal(1,"not all32 envelopes active");
        phase_check=1;
        full_file=$fopen("digital_pcm32.txt","w");
        if(!full_file)$fatal(1,"cannot open PCM evidence");
        repeat(24000)begin frame;$fdisplay(full_file,"%0d",$signed(pcm));end
        $fclose(full_file);
        // 释放第18路(2049Hz)。其他31路相位必须持续使用各自频率步长。
        mask=32'hfffdffff;
        repeat(2600)frame;
        if(audible!==32'hfffdffff || dut.synth.envelopes[17]!==0)
            $fatal(1,"single voice did not release independently");
        off_file=$fopen("digital_pcm31_voice18_off.txt","w");
        repeat(7500)begin frame;$fdisplay(off_file,"%0d",$signed(pcm));end
        $fclose(off_file);
        mask=32'hffffffff;repeat(1000)frame;
        if(audible!==32'hffffffff)$fatal(1,"single voice did not restore");
        phase_check=0;test_mode=0;mask=0;clear_audio=1;
        repeat(2)@(negedge clk);clear_audio=0;owned=0;
        note_on=1;@(negedge clk);note_on=0;
        repeat(1000)begin frame;if(pcm!=0)nonzero_normal=nonzero_normal+1;end
        if(nonzero_normal<100)$fatal(1,"normal playing not restored");
        $display("OSCILLATOR_AUDIO_TEST_PASS frames=%0d voices=32 max_pcm=%0d normal=%0d",frame_count,max_level,nonzero_normal);
        $finish;
    end
    initial begin #150000000;$fatal(1,"oscillator audio timeout");end
endmodule
