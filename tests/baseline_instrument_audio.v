// 声音层：声部分配→波表旋律→双鼓混音→去直流→可选低通→音量→PT8211。
// 所有寄存器使用 27MHz clk；fs_tick/frame_done 是时钟使能，不是新时钟。
// 输出是板载 3.5mm 耳机链路，不驱动外部 MAX98357。
module baseline_instrument_audio #(parameter LOWPASS_ENABLE=1,parameter NUM_VOICES=32)(
    input clk,input rst_n,input note_on,input note_off,input [6:0] note,
    input [7:0] velocity,input [3:0] timbre,
    input [7:0] slider_volume,input signed [8:0] slider_pitch,
    input hit0,input hit1,input [7:0] velocity0,input [7:0] velocity1,
    input digital_zero_test,input filter_enable,
    output hp_bck,output hp_ws,output hp_din,output overrun,
    output monitor_tick,output [15:0] monitor_pcm,
    output signed [8:0] monitor_pitch,output [NUM_VOICES-1:0] monitor_busy
);
    wire fs_tick,frame_done;
    wire [NUM_VOICES-1:0] gate,retrigger,voice_busy;
    wire [NUM_VOICES*7-1:0] note_bus;
    wire [NUM_VOICES*8-1:0] vel_bus;
    wire [NUM_VOICES*4-1:0] timbre_bus;
    wire signed [8:0] pitch_smooth;
    wire [15:0] mixed,kick_sample,snare_sample,mix_sample;
    wire [15:0] dc_sample,clean_sample,sample;
    wire kick_busy,snare_busy;
    voice_allocator #(.NUM_VOICES(NUM_VOICES),.ONE_SHOT_GATES(0)) u_alloc(
        .clk(clk),.rst_n(rst_n),.fs_tick(fs_tick),.note_on(note_on),.note_off(note_off),
        .note(note),.velocity(velocity),.timbre(timbre),.voice_busy(voice_busy),
        .gate(gate),.retrigger(retrigger),.note_bus(note_bus),.vel_bus(vel_bus),.timbre_bus(timbre_bus));
    wavetable_synth #(.NUM_VOICES(NUM_VOICES)) synth(
        .clk(clk),.rst_n(rst_n),.fs_tick(fs_tick),.test_mode(1'b0),.gate(gate),.retrigger(retrigger),
        .note_bus(note_bus),.vel_bus(vel_bus),.timbre_bus(timbre_bus),.pitch(pitch_smooth),
        .sample(mixed),.frame_done(frame_done),.overrun(overrun),.voice_busy(voice_busy));
    drum_voice kick(.clk(clk),.rst_n(rst_n),.fs_tick(fs_tick),.clear(digital_zero_test),
        .hit(hit0),.velocity(velocity0),.sample(kick_sample),.busy(kick_busy));
    snare_voice snare(.clk(clk),.rst_n(rst_n),.fs_tick(fs_tick),.clear(digital_zero_test),
        .hit(hit1),.velocity(velocity1),.sample(snare_sample),.busy(snare_busy));
    audio_mix mixer(.melody(mixed),.kick(kick_sample),.snare(snare_sample),.sample(mix_sample));

    // quiet 等待旋律尾音和鼓衰减结束，再等待 128 个采样帧。
    // 不能只看松键，否则会截断尾音并产生突变声。
    reg [7:0] idle_frames;
    reg quiet;
    wire sound_active=(|gate) || (|voice_busy) || note_on || hit0 || hit1 || kick_busy || snare_busy;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin idle_frames<=128;quiet<=1;end
        else if(sound_active) begin idle_frames<=0;quiet<=0;end
        else if(fs_tick) begin
            if(idle_frames<128) idle_frames<=idle_frames+1'b1;
            if(idle_frames>=127) quiet<=1;
        end
    end
    // frame_done 表示旋律 PCM 算完。保留原寄存器延迟和非阻塞赋值顺序：
    // 每级在上升沿读取的是上一个 clk 的上级输出，不是同一沿的新值。
    dc_blocker dc(.clk(clk),.rst_n(rst_n && !quiet),.tick(frame_done),
        .sample_in(mix_sample),.sample_out(dc_sample));
    audio_cleanup #(.LOWPASS_ENABLE(LOWPASS_ENABLE)) cleanup(.clk(clk),.rst_n(rst_n),
        .tick(frame_done),.quiet(quiet),.enable(filter_enable),
        .sample_in(dc_sample),.sample_out(clean_sample));
    audio_controls controls(.clk(clk),.rst_n(rst_n),.fs_tick(fs_tick),
        .sample_in(clean_sample),.volume(slider_volume),.pitch_in(slider_pitch),
        .pitch_smooth(pitch_smooth),.sample_out(sample));
    // 空闲/诊断强制送数字零；DAC、耳机模拟级和电脑输入仍可能产生噪声。
    wire [15:0] headphone_sample=(quiet || digital_zero_test)?16'd0:sample;
    pt8211_driver u_pt8211(.clk(clk),.rst_n(rst_n),.sample(headphone_sample),
        .bck(hp_bck),.ws(hp_ws),.din(hp_din),.fs_tick(fs_tick));
// 采样时刻与PT8211装载时刻一致，不读取串行DIN来反推波形。
    assign monitor_tick=fs_tick;
    assign monitor_pcm=headphone_sample;
    assign monitor_pitch=pitch_smooth;
    assign monitor_busy=voice_busy | gate;
endmodule
