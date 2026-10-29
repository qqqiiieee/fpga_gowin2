// Direct-key PT8211 headphones plus two independent pressure percussion pads.
// PA_EN belongs to the ON-BOARD headphone circuit, not the external MAX98357.
module legacy_top #(parameter LOWPASS_ENABLE=1,parameter VIRTUAL_ADC_CYCLES=63390)(
 input clk,output [3:0] matrix_rows,input [3:0] matrix_cols,
 output hp_bck,output hp_ws,output hp_din,output pa_en,
 output amp_bck,output amp_lrc,output amp_din,inout adc_scl,inout adc_sda,
 output [3:0] timbre_led_n,input uart_rx,output uart_tx);
 localparam NUM_VOICES=32;
 reg [7:0] por_cnt=0;reg rst_n=0;
 always @(posedge clk) begin
   if(por_cnt!=255) por_cnt<=por_cnt+1'b1;
   rst_n<=(por_cnt==255);
 end
 wire note_on,note_off;wire [6:0] note;wire [7:0] velocity;wire [3:0] timbre;
 wire [15:0] key_state;wire [3:0] selected_timbre;wire keypad_ghost;
 wire digital_zero_test,physical_zero_test;
 wire remote_active,remote_zero,remote_park,remote_accepted;
 wire fs_tick,frame_done,overrun;wire sliders_ready,adc_stale;
 wire [15:0] remote_keys;wire [7:0] remote_velocity,remote_seq;
 wire [63:0] remote_adc;
 reg remote_previous;
 always @(posedge clk or negedge rst_n)
   if(!rst_n) remote_previous<=0;else remote_previous<=remote_active;
 wire mode_changed=(remote_previous!=remote_active);
 wire controls_rst_n=rst_n && !mode_changed;
 assign digital_zero_test=physical_zero_test || (remote_active && remote_zero);
 reg [63:0] physical_adc;
 wire hw_adc_valid,hw_adc_fault;wire [1:0] hw_adc_channel;wire [15:0] hw_adc_data;
 always @(posedge clk or negedge rst_n)
   if(!rst_n) physical_adc<=0;
   else if(hw_adc_valid) physical_adc[hw_adc_channel*16 +: 16]<=hw_adc_data;
 // Injection is after ADC conversion and before all original control processing.
 // 63390 clk/sample matches the measured healthy I2C+conversion cadence: 7.043ms/pad.
 // Real matrix row pins and the analog sensor circuit remain electrically unchanged.
 reg [15:0] virtual_timer;reg [2:0] virtual_step;
 reg virtual_valid;reg [1:0] virtual_channel;reg [15:0] virtual_data;
 function [1:0] scheduled_channel;
   input [2:0] step;
   begin case(step)
     0,3:scheduled_channel=0;1,4:scheduled_channel=1;
     2:scheduled_channel=2;default:scheduled_channel=3;
   endcase end
 endfunction
 always @(posedge clk or negedge rst_n) begin
   if(!rst_n) begin virtual_timer<=0;virtual_step<=0;virtual_valid<=0;virtual_channel<=0;virtual_data<=0;end
   else begin
     virtual_valid<=0;
     if(!remote_active || mode_changed) begin virtual_timer<=0;virtual_step<=0;end
     else if(virtual_timer==VIRTUAL_ADC_CYCLES-1) begin
       virtual_timer<=0;virtual_valid<=1;virtual_channel<=scheduled_channel(virtual_step);
       virtual_data<=remote_adc[scheduled_channel(virtual_step)*16 +: 16];
       virtual_step<=(virtual_step==5)?0:virtual_step+1'b1;
     end else virtual_timer<=virtual_timer+1'b1;
   end
 end
 wire [7:0] remote_status={overrun,keypad_ghost,sliders_ready,adc_stale,hw_adc_fault,3'b000};
 remote_debug_link link(.clk(clk),.rst_n(rst_n),.uart_rx(uart_rx),.uart_tx(uart_tx),
   .physical_keys(key_state),.physical_adc(physical_adc),.status_flags(remote_status),
   .remote_active(remote_active),.zero_mode(remote_zero),.park_i2c(remote_park),
   .virtual_keys(remote_keys),.velocity(remote_velocity),.virtual_adc(remote_adc),
   .accepted(remote_accepted),.last_seq(remote_seq));
 headphone_mute_guard mute_guard(.clk(clk),.rst_n(rst_n),.key_state(key_state),
   .ghost(keypad_ghost),.mute_active(physical_zero_test));
 wire adc_valid=remote_active?virtual_valid:hw_adc_valid;
 wire adc_fault=remote_active?1'b0:hw_adc_fault;
 wire [1:0] adc_channel=remote_active?virtual_channel:hw_adc_channel;
 wire [15:0] adc_data=remote_active?virtual_data:hw_adc_data;
 wire pads_ready;
 reg [1:0] pad_seen;reg [23:0] adc_age;
 assign adc_stale=(adc_age>=13500000);
 // The pure-zero reference also parks I2C to expose noise from digital activity.
 ads1115_reader #(.PRESSURE_PRIORITY(1)) adc(.clk(clk),.rst_n(rst_n && !digital_zero_test && !(remote_active && remote_park)),
   .scl(adc_scl),.sda(adc_sda),.sample_valid(hw_adc_valid),.sample_channel(hw_adc_channel),
   .sample_data(hw_adc_data),.fault(hw_adc_fault));
 always @(posedge clk or negedge rst_n) begin
   if(!rst_n) begin pad_seen<=0;adc_age<=13500000;end
   else begin
     if(adc_valid) adc_age<=0;
     else if(adc_age<13500000) adc_age<=adc_age+1'b1;
     if(mode_changed || adc_fault || digital_zero_test || adc_stale) pad_seen<=0;
     else if(adc_valid && adc_channel<2) pad_seen[adc_channel]<=1;
   end
 end
 assign pads_ready=(&pad_seen) && !adc_fault && !adc_stale && !digital_zero_test;
 wire [7:0] slider_volume;wire signed [8:0] slider_pitch,pitch_smooth;
 wire [7:0] unused_color;
 slider_controls sliders(.clk(clk),.rst_n(controls_rst_n),.adc_valid(adc_valid),
   .adc_channel(adc_channel),.adc_data(adc_data),.volume(slider_volume),
   .pitch(slider_pitch),.ready(sliders_ready));
 wire hit0,hit1,kick_busy,snare_busy;wire [7:0] velocity0,velocity1;
 wire [15:0] kick_sample,snare_sample,mix_sample;
 pressure_adaptive pads(.clk(clk),.rst_n(controls_rst_n),.ready(pads_ready),.adc_valid(adc_valid),
   .adc_channel(adc_channel),.adc_data(adc_data),.hit0(hit0),.hit1(hit1),
   .velocity0(velocity0),.velocity1(velocity1));
 matrix_keypad #(.DEBOUNCE_FRAMES(3),.PERFORMANCE_MODE(1),.SELECT_ON_RELEASE(1)) u_keypad(
   .clk(clk),.rst_n(rst_n),.suppress_select(1'b0),.rows(matrix_rows),.cols(matrix_cols),.virtual_enable(remote_active),.virtual_keys(remote_keys),
   .velocity(remote_active?remote_velocity:8'd160),
   .note_on(note_on),.note_off(note_off),.note(note),.vel_out(velocity),
   .timbre_out(timbre),.key_state(key_state),.ghost_active(keypad_ghost),.selected_timbre(selected_timbre));
 wire [NUM_VOICES-1:0] gate,retrigger,voice_busy;
 wire [NUM_VOICES*7-1:0] note_bus;wire [NUM_VOICES*8-1:0] vel_bus;
 wire [NUM_VOICES*4-1:0] timbre_bus;
 voice_allocator #(.NUM_VOICES(NUM_VOICES),.ONE_SHOT_GATES(0)) u_alloc(
   .clk(clk),.rst_n(rst_n),.fs_tick(fs_tick),.note_on(note_on),.note_off(note_off),.note(note),
   .velocity(velocity),.timbre(timbre),.voice_busy(voice_busy),.gate(gate),.retrigger(retrigger),
   .note_bus(note_bus),.vel_bus(vel_bus),.timbre_bus(timbre_bus));
 wire [15:0] mixed,dc_sample,clean_sample,sample;
 legacy_shared_synth #(.NUM_VOICES(NUM_VOICES),.ONE_SHOT(0)) synth(
   .clk(clk),.rst_n(rst_n),.fs_tick(fs_tick),.diagnostic(1'b0),
   .gate(gate),.retrigger(retrigger),.note_bus(note_bus),.vel_bus(vel_bus),.timbre_bus(timbre_bus),
   .pitch(pitch_smooth),.color(8'd0),.sample(mixed),.frame_done(frame_done),.overrun(overrun),.voice_busy(voice_busy));
 drum_voice kick(.clk(clk),.rst_n(rst_n),.fs_tick(fs_tick),.clear(digital_zero_test),
   .hit(hit0),.velocity(velocity0),.sample(kick_sample),.busy(kick_busy));
 snare_voice snare(.clk(clk),.rst_n(rst_n),.fs_tick(fs_tick),.clear(digital_zero_test),
   .hit(hit1),.velocity(velocity1),.sample(snare_sample),.busy(snare_busy));
 audio_mix mixer(.melody(mixed),.kick(kick_sample),.snare(snare_sample),.sample(mix_sample));
 // Wait for the release envelope, then clear filter history and send exact zero.
 reg [7:0] idle_frames;reg quiet;
 wire sound_active=(|gate) || (|voice_busy) || note_on || hit0 || hit1 || kick_busy || snare_busy;
 always @(posedge clk or negedge rst_n) begin
   if(!rst_n) begin idle_frames<=128;quiet<=1;end
   else if(sound_active) begin idle_frames<=0;quiet<=0;end
   else if(fs_tick) begin
     if(idle_frames<128) idle_frames<=idle_frames+1'b1;
     if(idle_frames>=127) quiet<=1;
   end
 end
 // Bottom-row S14+S15 toggles the low-pass once per press, for an A/B comparison.
 reg filter_enable,filter_combo_armed;
 wire filter_combo=(key_state==16'h6000) && !keypad_ghost;
 always @(posedge clk or negedge rst_n) begin
   if(!rst_n) begin filter_enable<=1;filter_combo_armed<=1;end
   else begin
     if((key_state & 16'h6000)==0 && !keypad_ghost) filter_combo_armed<=1;
     if(filter_combo && filter_combo_armed) begin
       filter_enable<=!filter_enable;filter_combo_armed<=0;
     end
   end
 end
 dc_blocker dc(.clk(clk),.rst_n(rst_n && !quiet),.tick(frame_done),.sample_in(mix_sample),.sample_out(dc_sample));
 audio_cleanup #(.LOWPASS_ENABLE(LOWPASS_ENABLE)) cleanup(.clk(clk),.rst_n(rst_n),.tick(frame_done),
   .quiet(quiet),.enable(filter_enable),.sample_in(dc_sample),.sample_out(clean_sample));
 legacy_audio_controls controls(.clk(clk),.rst_n(rst_n),.fs_tick(fs_tick),.sample_in(clean_sample),
   .volume(slider_volume),.expression(8'd255),.pitch_in(slider_pitch),.pitch_smooth(pitch_smooth),
   .color_in(8'd0),.color_smooth(unused_color),.sample_out(sample));
 // S15+S16 held 0.5s is a PCM-zero reference, capped at 3s against a stuck chord.
 wire [15:0] headphone_sample=(quiet || digital_zero_test)?16'd0:sample;
 pt8211_driver u_pt8211(.clk(clk),.rst_n(rst_n),.sample(headphone_sample),
   .bck(hp_bck),.ws(hp_ws),.din(hp_din),.fs_tick(fs_tick));
 assign pa_en=1'b1;
 assign amp_bck=1'b0;assign amp_lrc=1'b0;assign amp_din=1'b0;
 // Brief startup flashes identify this image; note-on lights all four for 80ms.
 reg [23:0] startup_count;reg [21:0] note_led_timer;
 always @(posedge clk or negedge rst_n) begin
   if(!rst_n) begin startup_count<=0;note_led_timer<=0;end
   else begin
     if(startup_count<13500000) startup_count<=startup_count+1'b1;
     if(note_on || hit0 || hit1) note_led_timer<=2160000;
     else if(note_led_timer!=0) note_led_timer<=note_led_timer-1'b1;
   end
 end
 reg [23:0] status_count;
 always @(posedge clk or negedge rst_n)
   if(!rst_n) status_count<=0;else status_count<=status_count+1'b1;
 // NEW image: LED3/LED4 alternate when ADC is unavailable; keys stay playable.
 assign timbre_led_n=(startup_count<13500000)?{4{startup_count[21]}}:
   (digital_zero_test?4'b0000:((adc_fault || adc_stale)?
    {1'b1,status_count[22],!status_count[22],1'b1}:
    ((note_led_timer!=0)?4'b0000:~selected_timbre)));
endmodule
