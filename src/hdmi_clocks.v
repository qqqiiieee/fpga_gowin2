// HDMI时钟发生器，仅使用Gowin专用rPLL与CLKDIV资源。
// 输入27MHz，PLL126MHz（27×14/3）；CLKDIV /5得到25.2MHz，VCO504MHz。
// rst_n异步低有效；locked只是PLL状态，下游仍需各域复位同步器。
// divider_reset_sync在serial域延迟三拍释放，避免直接在像素域操纵IO时钟复位。
// 实例u_pll/u_div与父层u_display的名字被SDC使用；重命名须同步修改约束并重建。
// 不可换成逻辑计数器生成像素时钟；专用时钟网络是输出时序前提。

// 27 MHz *14/3=126 MHz; dedicated CLKDIV /5 =25.2 MHz.
// PLL VCO=504 MHz (ODIV=4). No fabric-generated pixel clock.
module hdmi_clocks(input clk27,input rst_n,output serial_clk,
    output pixel_clk,output locked);
    rPLL u_pll(.CLKOUT(serial_clk),.LOCK(locked),
        .CLKOUTP(),.CLKOUTD(),.CLKOUTD3(),.CLKIN(clk27),
        .CLKFB(1'b0),.RESET(!rst_n),.RESET_P(1'b0),
        .FBDSEL(6'd0),.IDSEL(6'd0),.ODSEL(6'd0),
        .PSDA(4'd0),.DUTYDA(4'd0),.FDLY(4'd0));
    defparam u_pll.FCLKIN="27";
    defparam u_pll.IDIV_SEL=2;
    defparam u_pll.FBDIV_SEL=13;
    defparam u_pll.ODIV_SEL=4;
    defparam u_pll.DEVICE="GW2A-18C";
    defparam u_pll.CLKFB_SEL="internal";
    defparam u_pll.DYN_IDIV_SEL="false";
    defparam u_pll.DYN_FBDIV_SEL="false";
    defparam u_pll.DYN_ODIV_SEL="false";
    defparam u_pll.DYN_DA_EN="false";
    defparam u_pll.PSDA_SEL="0000";
    defparam u_pll.DUTYDA_SEL="1000";
    // Release the divider reset in its own clock domain, after PLL lock.
    wire clock_reset_n=rst_n && locked;
    (* syn_preserve=1 *) reg [2:0] divider_reset_sync;
    always @(posedge serial_clk or negedge clock_reset_n)
        if(!clock_reset_n)divider_reset_sync<=0;
        else divider_reset_sync<={divider_reset_sync[1:0],1'b1};
    CLKDIV u_div(.HCLKIN(serial_clk),.CLKOUT(pixel_clk),
        .RESETN(divider_reset_sync[2]),.CALIB(1'b1));
    defparam u_div.DIV_MODE="5";
    defparam u_div.GSREN="false";
endmodule
