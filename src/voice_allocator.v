// 作用：为 note_on 选择合成声部，锁存音高、力度和音色，输出 gate 与复触发脉冲。
// 本模块只分配控制信息，不生成/处理 PCM；下游合成输出才是 16 位二补码 PCM。
// clk 为工程 27 MHz 主时钟；rst_n 低有效异步清零全部声部元数据、gate 和保护状态。
// note_on/note_off 是 clk 域内的事件脉冲，不在本模块做边沿检测；note 为 7 位音符号，
// velocity 为 8 位力度，timbre 为 4 位音色编号，均在分配发生时锁存。
// fs_tick 是同域的 93.75 kHz 采样使能（每 288 个 clk 周期），仅供可选 ONE_SHOT
// gate 回收保护推进；普通分配和 note_off 处理在每个 clk 上升沿进行。
// voice_busy 由合成器报告包络/状态尚未结束，gate 表示按键保持，两者意义不同。
// gate 拉低后释放尾音仍可能 busy，因此优先选择 gate=0 且 busy=0 的完全空闲声部。
// NUM_VOICES 默认是 8，本工程顶层显式设置为 32：这是独立音符状态/尾音槽数量。
// 4 位 timbre 可表示 16 个音色编号，声部数量与音色数量不是同一个概念；
// 每个声部可锁存任一编号，选择新音色不会在这里重写正在发声声部的 timbre。
// 本工程 ONE_SHOT_GATES=0，wavetable_synth 使用持续 gate 和释放尾音。
// 可复用的一次性模式参数仍保留在代码里，但下面的自动回收保护在当前配置不启用。
// NUM_VOICES 需为正且不超过256，以匹配8位轮转指针；合成器帧预算另有限制。
// ONE_SHOT_GATES 默认0，按布尔选项使用；velocity 为0..255，timbre 为0..15。
// 输出没有独立valid：gate/元数据持续保持，retrigger 的置位就是该槽的新分配事件。
module voice_allocator #(parameter NUM_VOICES=8,parameter ONE_SHOT_GATES=0)(
    input clk,input rst_n,input note_on,input note_off,input [6:0] note,
    input [7:0] velocity,input [3:0] timbre,input [NUM_VOICES-1:0] voice_busy,
    output [NUM_VOICES-1:0] gate,output [NUM_VOICES-1:0] retrigger,
    output [NUM_VOICES*7-1:0] note_bus,output [NUM_VOICES*8-1:0] vel_bus,
    output [NUM_VOICES*4-1:0] timbre_bus,input fs_tick);
    // 每个槽分别保存 7 位音高、8 位力度和 4 位音色；复用该槽时才覆盖这些值。
    // gates 是持续电平；triggers 用于已有 gate 仍为高时也能重新触发下游包络。
    // started 仅为可选一次性模式的“已看到新声部忙碌”标记，不等同于 gate。
    reg [6:0] notes [0:NUM_VOICES-1];
    reg [7:0] velocities [0:NUM_VOICES-1];
    reg [3:0] timbres [0:NUM_VOICES-1];
    reg [NUM_VOICES-1:0] gates,triggers,started;
    // 可选一次性模式：旧声部的 busy=1 不能视为新分配已被合成器接收的确认。
    // wait_snapshot 等下一次 fs_tick 取快照，wait_cycle 再覆盖随后的一帧处理周期。
    // 两者都清除后才允许把 busy=1 记入 started；随后 busy=0 才回收 gate。
    // 当前 ONE_SHOT_GATES=0 时，掩码虽在 note_on 时置位，却不推进/参与 gate 回收。
    reg [NUM_VOICES-1:0] wait_snapshot,wait_cycle;
    // 轮转指针是 8 位；当前 32 声部落在其可表示范围内。
    // 每次分配后指向所选槽的下一个索引，末槽回绕到 0。
    reg [7:0] ptr;
    integer target,i;
    reg found;
    // 组合选择顺序：
    // 1. 按索引从低到高选 gate=0、busy=0 的槽，尽量保留尚在释放的尾音。
    // 2. 若没有完全空闲槽，按低索引选 gate=0 的槽，允许覆盖一条释放中的尾音。
    // 3. 若所有 gate 都为 1，保留 target=ptr，轮转抢占仍按下的声部。
    // 空闲/尾音候选用的是首次匹配索引，只有最后一层兜底按 ptr 轮转。
    // 不按音符号查找已分配槽；重复 note_on 可以分到不同槽，也可以覆盖旧槽。
    always @(*) begin
      target=ptr;found=0;
      for(i=0;i<NUM_VOICES;i=i+1)
        if(!found && !gates[i] && !voice_busy[i]) begin target=i;found=1;end
      if(!found) for(i=0;i<NUM_VOICES;i=i+1)
        if(!found && !gates[i]) begin target=i;found=1;end
    end
    integer k;
    always @(posedge clk or negedge rst_n) begin
      if(!rst_n) begin
        gates<=0;triggers<=0;started<=0;wait_snapshot<=0;wait_cycle<=0;ptr<=0;
        for(k=0;k<NUM_VOICES;k=k+1) begin notes[k]<=0;velocities[k]<=0;timbres[k]<=0;end
      end else begin
        // 无新 note_on 时，复触发向量在下一个 clk 清零，因此事件通常宽一个主时钟。
        // 若调用者持续拉高 note_on，则每个 clk 都会再次分配；这里不会自动限为一次。
        triggers<=0;
        // 非阻塞赋值使 wait_cycle 接到本沿之前的 wait_snapshot。
        // 新分配在本沿后面的 note_on 分支重新置位，优先于此处的整向量清除。
        if(ONE_SHOT_GATES && fs_tick) begin
          wait_snapshot<=0;wait_cycle<=wait_snapshot;
        end
        // ONE_SHOT_GATES=1 才启用 busy 确认后自动撤销 gate 的逻辑。
        // 此可选回收模式要求下游在 gate 尚高时也能自行结束 busy；不能仅打开本参数
        // 就把持续门控合成器变成一次性音源。当前 wavetable_synth 没有 ONE_SHOT/color 接口。
        // 生产 ONE_SHOT_GATES=0：gate 保持到 note_off/复位，复用时置1；busy=0不自动撤销。
        // 显式 note_off 在两种模式都会处理；此分支不屏蔽下方的按键释放事件。
        if(ONE_SHOT_GATES) for(k=0;k<NUM_VOICES;k=k+1) begin
          if(gates[k] && voice_busy[k] && !wait_snapshot[k] && !wait_cycle[k]) started[k]<=1;
          if(started[k] && !voice_busy[k]) begin gates[k]<=0;started[k]<=0;end
        end
        // note_off 清除所有音符号相同的槽的 gate，不清除元数据，不直接切断 busy 尾音。
        // 声部后续释放由 wavetable_synth 执行；保留音色和力度供释放阶段使用。
        if(note_off) for(k=0;k<NUM_VOICES;k=k+1) if(notes[k]==note) gates[k]<=0;
        // 同一 clk 同时 note_off/note_on 时，此处更后的非阻塞赋值让目标 gate=1，
        // 其他同音槽仍可能被 note_off 释放。复用槽时重新锁存三类参数并发出 retrigger。
        // velocity=0 在此也照常分配；本模块没有把零力度自动转换为 note_off 的规则。
        if(note_on) begin
          notes[target]<=note;velocities[target]<=velocity;timbres[target]<=timbre;
          gates[target]<=1;triggers[target]<=1;started[target]<=0;
          wait_snapshot[target]<=1;wait_cycle[target]<=1;
          ptr<=(target==NUM_VOICES-1)?0:target+1;
        end
      end
    end
    // retrigger 的短脉冲由下游 wavetable_synth.pending_triggers 锁存，直到相应声部
    // 被处理时消费；因此可在 gate 已为 1 的复用/再次触发情况下重启包络。
    // 该事件锁存与 ONE_SHOT_GATES 的旧 busy 回收保护是两套不同机制。
    // 输出只是内部寄存器映射；总线槽 g 从低位起排列，不能把它当 PCM 或音色列表。
    assign gate=gates;assign retrigger=triggers;
    genvar g;
    // 第 g 个声部占 note_bus[g*7+:7]、vel_bus[g*8+:8]、timbre_bus[g*4+:4]。
    // 可变声部数量只改变槽数/总线宽度，每槽字段宽度仍为 7/8/4 bit。
    generate for(g=0;g<NUM_VOICES;g=g+1) begin : buses
      assign note_bus[g*7+:7]=notes[g];
      assign vel_bus[g*8+:8]=velocities[g];
      assign timbre_bus[g*4+:4]=timbres[g];
    end endgenerate
endmodule
