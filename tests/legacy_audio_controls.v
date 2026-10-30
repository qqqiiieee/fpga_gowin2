// Audio-rate Q8 smoothing prevents zipper noise from asynchronous control changes.
module legacy_audio_controls(input clk,input rst_n,input fs_tick,input [15:0] sample_in,
    input [7:0] volume,input [7:0] expression,input signed [8:0] pitch_in,input [7:0] color_in,
    output signed [8:0] pitch_smooth,output [7:0] color_smooth,output reg [15:0] sample_out);
    reg signed [17:0] gain_q;
    reg signed [18:0] pitch_q;
    reg signed [17:0] color_q;
    wire signed [18:0] color_distance=$signed({2'b00,color_in,8'b0})-$signed(color_q);
    wire signed [18:0] color_step=color_distance>>>7;
    wire [15:0] gain_product=volume*expression;
    wire signed [17:0] gain_target=$signed({2'b00,gain_product});
    wire signed [18:0] pitch_target=$signed(pitch_in)<<<8;
    wire signed [18:0] gain_distance=$signed(gain_target)-$signed(gain_q);
    wire signed [19:0] pitch_distance=$signed(pitch_target)-$signed(pitch_q);
    wire signed [18:0] gain_step=gain_distance>>>8;
    wire signed [19:0] pitch_step=pitch_distance>>>8;
    always @(posedge clk or negedge rst_n) begin
      if(!rst_n) begin gain_q<=18'sd45900;pitch_q<=0;color_q<=18'sd24576;end
      else if(fs_tick) begin
        color_q<=color_q+((color_step==0 && color_distance!=0)?19'sd1:color_step);
        gain_q<=gain_q+((gain_step==0 && gain_distance!=0)?19'sd1:gain_step);
        pitch_q<=pitch_q+((pitch_step==0 && pitch_distance!=0)?20'sd1:pitch_step);
      end
    end
    assign color_smooth=color_q[15:8];
    assign pitch_smooth=pitch_q>>>8;
    wire signed [32:0] scaled=$signed(sample_in)*$signed({1'b0,gain_q[15:8]});
    always @(posedge clk or negedge rst_n)
      if(!rst_n) sample_out<=0;else sample_out<=scaled>>>8;
endmodule
