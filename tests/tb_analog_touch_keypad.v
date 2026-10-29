`timescale 1ns/1ps
// 按公开接口送样/标定；期望来自独立距离模型，覆盖压缩/乱序与整个12bit输入域。
module tb_analog_touch_keypad;
    parameter TEST_STABLE = 3;
    localparam STALE = 160;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, sample_valid=0, cal_write=0;
    reg [11:0] sample_data=0, cal_value=0;
    reg [3:0] cal_index=0;
    wire [15:0] keys;
    wire [11:0] raw_value;
    wire valid, fault;
    integer centers[0:15];
    reg [11:0] defaults[0:15];
    integer checks=0, judgments=0, i,j,k,v,expected,pulses;

    analog_touch_keypad #(.STABLE_SAMPLES(TEST_STABLE), .STALE_CYCLES(STALE)) dut(
        .clk(clk), .rst_n(rst_n), .sample_valid(sample_valid), .sample_data(sample_data),
        .cal_write(cal_write), .cal_index(cal_index), .cal_value(cal_value),
        .keys(keys), .raw_value(raw_value), .valid(valid), .fault(fault));

    task check;
        input condition;
        input [1023:0] message;
        begin
            checks=checks+1;
            if(condition !== 1'b1) $fatal(1,"%0s raw=%0d keys=%h valid=%b fault=%b",message,raw_value,keys,valid,fault);
        end
    endtask
    always @(negedge clk) if(rst_n) begin
        check((keys & (keys-16'd1)) == 0, "output must remain onehot or zero");
    end
    task cycles;
        input integer n;
        begin repeat(n) @(negedge clk); end
    endtask
    task reset_device;
        begin
            @(negedge clk); rst_n=0; sample_valid=0; cal_write=0;
            cycles(3);
            check(keys==0 && !valid && fault && raw_value==0,"reset outputs");
            for(i=0;i<16;i=i+1) centers[i]=defaults[i];
            rst_n=1;
            cycles(2);
        end
    endtask
    task start_sample;
        input integer value;
        begin
            @(negedge clk); sample_data=value; sample_valid=1;
            @(negedge clk); sample_valid=0;
            check(raw_value==value,"raw_value did not latch input sample");
        end
    endtask
    task send;
        input integer value;
        input integer expected_valid;
        input integer expected_fault;
        begin
            start_sample(value);
            pulses=0;
            repeat(35) begin
                @(negedge clk);
                if(valid) pulses=pulses+1;
            end
            check(pulses==expected_valid,"completed-sample valid pulse count");
            check(fault==expected_fault,"fault diagnosis mismatch");
            judgments=judgments+1;
        end
    endtask
    task press;
        input integer index;
        integer n;
        begin
            for(n=1;n<=TEST_STABLE;n=n+1) begin
                send(centers[index],1,0);
                if(n<TEST_STABLE) check(keys==0,"pressed before stable sample count");
            end
            check(keys== (16'h0001<<index),"rowmajor bit mapping");
        end
    endtask
    task write_center;
        input integer index;
        input integer value;
        begin
            @(negedge clk); cal_index=index; cal_value=value; cal_write=1;
            @(negedge clk); cal_write=0;
            centers[index]=value;
            check(keys==0 && !valid && fault,"calibration must release and invalidate immediately");
        end
    endtask
    // 参考模型不使用DUT状态、内部中心或其接收窗。
    task classify;
        input integer value;
        output integer result;
        integer a,b,d,min_distance,next_distance,chosen,local_gap,half_window;
        reg invalid_table,collision;
        begin
            min_distance=99999; next_distance=99999; chosen=0; invalid_table=0; collision=0;
            for(a=0;a<16;a=a+1) begin
                if(centers[a]<8 || centers[a]>4094) invalid_table=1;
                d=(value>centers[a]) ? value-centers[a] : centers[a]-value;
                if(d<min_distance) begin next_distance=min_distance; min_distance=d; chosen=a; end
                else if(d<next_distance) next_distance=d;
            end
            local_gap=centers[chosen];
            for(b=0;b<16;b=b+1) if(b!=chosen) begin
                d=(centers[b]>centers[chosen]) ? centers[b]-centers[chosen] : centers[chosen]-centers[b];
                if(d<12) collision=1;
                if(d<local_gap) local_gap=d;
            end
            half_window=local_gap/4;
            if(half_window>32) half_window=32;
            if(half_window<2) half_window=2;
            if(invalid_table) result=-1;
            else if(value<4) result=-2;
            else if(collision || min_distance>half_window || next_distance-min_distance<=2) result=-1;
            else result=chosen;
        end
    endtask

    initial begin
        $readmemh("src/touch_centers.hex",defaults);
        reset_device;
        send(0,1,0); check(keys==0,"idle zero");
        send(3,1,0); check(keys==0,"idle upper edge");
        send(4,0,1); check(keys==0,"raw4 must not become idle or key");
        // 全16键确认物理行位置，两个不稳定样本不能触发。
        for(j=0;j<16;j=j+1) begin
            send(0,1,0);
            press(j);
            send(0,1,0); check(keys==0,"release must be immediate");
        end
        if(TEST_STABLE>1) begin
            for(j=0;j<TEST_STABLE-1;j=j+1) send(centers[0],1,0);
            check(keys==0,"transient key accepted");
            send(centers[1],1,0);
            check(keys==0,"cross-band transient accepted");
            send(4095,0,1); check(keys==0,"unmatched rail accepted");
            for(j=0;j<TEST_STABLE-1;j=j+1) send(centers[1],1,0);
            check(keys==0,"invalid sample did not clear debounce");
        end
        send(0,1,0); press(2);
        send(4095,0,1); check(keys==0,"unmatched input did not release held key");
        press(3); cycles(STALE+3); check(keys==0 && fault && !valid,"stale did not release");
        press(4);
        // 校准途中取消旧帧：覆盖搜索早/晚期及提交拍，旧结果不得出现在输出。
        for(k=0;k<=33;k=k+1) begin
            start_sample(centers[4]);
            if(k>0) cycles(k);
            cal_index=4; cal_value=centers[4]; cal_write=1;
            @(negedge clk); cal_write=0;
            check(keys==0 && !valid,"in-flight calibration release");
            repeat(37) begin @(negedge clk); check(keys==0 && !valid,"old-center frame leaked after write"); end
        end
        // 校准与输入同拍：以校准为准，后续必须从新样本重新计满消抖。
        @(negedge clk); cal_write=1; cal_index=0; cal_value=3000;
        sample_valid=1; sample_data=centers[0];
        @(negedge clk); cal_write=0; sample_valid=0; centers[0]=3000;
        cycles(36); check(keys==0 && !valid,"same-cycle sample escaped calibration cancellation");
        send(defaults[0],0,1); press(0);
        reset_device; send(3000,0,1); press(0);
        // 整组压缩再乱序：最低档约39，重现固定idle<40会吞键的情形。
        for(j=0;j<16;j=j+1) write_center(j,defaults[(j*5+3)%16]/2);
        for(j=0;j<16;j=j+1) begin send(0,1,0); press(j); end
        // 对缩半且乱序的中心穷举4096个raw，逐点核对窗外拒绝/空闲/有效判断。
        for(v=0;v<4096;v=v+1) begin
            classify(v,expected);
            send(v,(expected!=-1),(expected==-1));
            if(expected<0) check(keys==0,"oracle invalid/idle must release");
            else check(keys==0 || keys==(16'h1<<expected),"oracle candidate index mismatch");
        end
        // 合法最小间距12，可识别两端；中点有歧义，无键。
        for(j=0;j<16;j=j+1) write_center(j,100+j*100);
        write_center(1,112);
        send(0,1,0); press(0); send(0,1,0); press(1);
        send(106,0,1); check(keys==0,"equidistant midpoint accepted");
        send(103,1,0); send(104,0,1); check(keys==0,"adaptive window boundary");
        // 最后一项成为最近候选/最近邻，捕获顺序扫描最后一拍漏算错误。
        write_center(15,111);
        send(100,0,1); check(keys==0,"gap11 must be rejected");
        send(111,0,1); check(keys==0,"last center close pair accepted");
        write_center(15,100);
        send(100,0,1); check(keys==0,"duplicate centers accepted");
        // 0、7、4095非法；8和4094合法，低端动态窗最低为2。
        write_center(15,1600); write_center(1,200);
        write_center(0,0); send(0,0,1);
        write_center(0,7); send(7,0,1);
        write_center(0,4095); send(4095,0,1);
        write_center(0,8); send(0,1,0); press(0);
        send(6,1,0); send(5,0,1); check(keys==0,"low center quarter-gap window");
        write_center(0,4094); send(0,1,0); press(0);
        // 超吞吐输入会取消旧判定并清消抖，不会重放之前确认的键。
        start_sample(4094); cycles(4); start_sample(200);
        check(keys==0 && fault,"overrun must release"); cycles(35);
        if(TEST_STABLE>1) check(keys==0,"overrun kept previous debounce");
        else check(keys==2,"STABLE1 overrun recovery");
        reset_device; send(0,1,0); press(15);
        $display("ANALOG_TOUCH_KEYPAD_TEST_PASS checks=%0d judgments=%0d stable=%0d raw_exhaustive=4096",
                 checks,judgments,TEST_STABLE);
        $finish;
    end
    initial begin #20000000; $fatal(1,"touch test timeout"); end
endmodule
