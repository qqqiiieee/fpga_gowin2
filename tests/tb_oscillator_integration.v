// 实体键盘模型接入完整耳机顶层；ADC缺席不能阻止验证模式。
module tb_oscillator_integration;
    reg clk=0;always #5 clk=~clk;
    reg [15:0] keys=0;
    wire [3:0] rows,cols,leds;
    genvar c;
    generate for(c=0;c<4;c=c+1)begin
        assign cols[c]=!(((rows[0]===1'b0)&&keys[c]) || ((rows[1]===1'b0)&&keys[c+4]) ||
                        ((rows[2]===1'b0)&&keys[c+8]) || ((rows[3]===1'b0)&&keys[c+12]));
    end endgenerate
    tri1 scl,sda;
    wire tick,owned,mode,overrun,sweep;wire [4:0] index;
    wire [15:0] pcm;wire [31:0] gates,audible;wire [5:0] requested;
    instrument_audio_top #(.TEST_HOLD_SAMPLES(16),.TEST_MAX_SAMPLES(500000),
        .TEST_SWEEP_HALF_SAMPLES(400),.TEST_RAMP_DIV(1)) dut(
        .clk(clk),.matrix_rows(rows),.matrix_cols(cols),.adc_scl(scl),.adc_sda(sda),
        .uart_rx(1'b1),.uart_tx(),.hp_bck(),.hp_ws(),.hp_din(),.pa_en(),
        .amp_bck(),.amp_lrc(),.amp_din(),.timbre_led_n(leds),
        .monitor_tick(tick),.monitor_pcm(pcm),.monitor_test_owned(owned),.monitor_test_mode(mode),
        .monitor_test_gate(gates),.monitor_test_busy(audible),.monitor_test_requested(requested),
        .monitor_test_sweep(sweep),.monitor_test_index(index));
    defparam dut.input_hub.u_keypad.ROW_CYCLES=16;
    defparam dut.input_hub.u_keypad.DEBOUNCE_FRAMES=2;
    task frames;
        input integer n;integer k;
        begin for(k=0;k<n;k=k+1)begin
            @(negedge clk);while(!tick)@(negedge clk);
            if(dut.overrun)$fatal(1,"integration overrun");
        end end
    endtask
    task press;
        input [15:0] value;
        // 独立包络释放仍会保留约25ms尾音，等3200帧后再断言真实活跃路数。
        begin keys=value;frames(80);keys=0;frames(3200);end
    endtask
    reg [3:0] original_timbre;
    integer nonzero=0,k;
    initial begin
        repeat(1000)@(negedge clk);
        original_timbre=dut.selected_timbre;
        keys=16'h5000;frames(600);keys=0;frames(1200);
        if(!owned || !mode || requested!=32 || gates!==32'hffffffff || audible!==32'hffffffff)
            $fatal(1,"long chord did not start full32");
        if(dut.selected_timbre!==original_timbre)$fatal(1,"test entry changed timbre");
        if(dut.audio.gate!==0)$fatal(1,"normal allocator contains test notes");
        if(dut.monitor_pitch!==0)$fatal(1,"test pitch not fixed");
        press(16'h0001);
        if(requested!=1 || gates!==1 || audible!==1)$fatal(1,"S1 count1 not integrated");
        press(16'h0010);
        if(requested!=32 || audible!==32'hffffffff)$fatal(1,"S5 count32 not integrated");
        keys=16'h0020;frames(80);keys=0;
        frames(50);
        if(!sweep || gates===32'hffffffff)$fatal(1,"S6 sweep not integrated");
        press(16'h0010); // S5取消逐路检查，恢复稳定32路。
        if(sweep || gates!==32'hffffffff)$fatal(1,"S5 failed to cancel sweep");
        keys=16'h8000;frames(400);
        if(!owned || mode || pcm!=0)$fatal(1,"exit must wait key release in silence");
        keys=0;frames(400);
        if(owned || mode || dut.selected_timbre!==original_timbre)$fatal(1,"normal state not restored");
        keys=16'h0020;
        for(k=0;k<1200;k=k+1)begin frames(1);if(pcm!=0)nonzero=nonzero+1;end
        if(nonzero<100)$fatal(1,"normal key no longer plays");
        keys=0;frames(2500);
        $display("OSCILLATOR_INTEGRATION_TEST_PASS full32/count/sweep/exit/normal nonzero=%0d",nonzero);$finish;
    end
    initial begin #80000000;$fatal(1,"integration timeout");end
endmodule
