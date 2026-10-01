# 多音色合成电子乐器引擎（FPGA）

2026 全国大学生嵌入式芯片与系统设计竞赛 · FPGA 创新设计赛道 · 高云半导体选题二
**「基于 FPGA 的实时多音色合成电子乐器引擎」**

## 硬件平台

- 开发板：Tang Primer 20K Dock（Sipeed）
- FPGA：高云 GW2A-LV18PG256C8/I7（GW2A-18C）
- 主时钟：27 MHz
- 音频输出：板载 PT8211 DAC（LSBJ 格式）→ LPA4809 功放 → 3.5mm 耳机孔
- 输入：板载按键（后续接入压力传感器做力度/表情控制）

## 架构

```
按键 ──> 复音分配器 ──> 8 个独立声部 ──> 混音器 ──> PT8211 驱动 ──> DAC
         (voice_allocator)   (voice × 8)    (mixer)   (pt8211_driver)
```

- **复音**：8 声部，每个声部有独立相位累加器 + 包络（评分点：独立振荡器数量 × 采样率）
- **合成**：DDS 相位累加 + 波表（正弦 256 点 + 线性插值；方波/锯齿/三角算术生成）
- **包络**：ADSR（Attack/Decay/Sustain/Release），峰值由力度 velocity 控制
- **采样率**：约 52.7 kHz（27MHz/512）

## 文件结构

```
src/
├── top.v               顶层：时钟/复位、按键→分配→声部→混音→DAC
├── voice.v             单复音振荡器：相位累加 + 波形选择 + ADSR + 力度
├── voice_allocator.v   8 声部轮询分配器
├── note_table.v        音符编号 → 相位增量（频率字）查表
├── sine_lut.v          正弦波表（256 点全周期 + 线性插值）
├── mixer.v             8 声部求和缩放
├── pt8211_driver.v     PT8211 DAC 串行输出驱动（LSBJ）
├── keypad.v            按键去抖 + 音符触发
├── sensor_interface.v  压力传感器接口（占位，待接入）
└── multi_tone.cst      引脚约束
```

## 编译与烧录

1. 用 Gowin IDE（云源软件）打开 `multi_tone_instrument.gprj`
2. 综合 → 布局布线 → 生成比特流（Run）
3. Gowin Programmer 烧录 `.fs` 文件

## 当前进度 / TODO

- [x] 框架搭建 + 8 声部复音 + ADSR + 4 音色 + PT8211 出声
- [x] 正弦波表 + 线性插值
- [ ] 压力传感器接入（力度 / 表情控制，≥2 维）
- [ ] 更多音色 / 效果器
- [ ] 迁移 Tang Primer 25K（GW5A-25，50MHz，MAX98357A I2S 输出）
