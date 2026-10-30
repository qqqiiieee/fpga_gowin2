"""Tk主线程仅处理界面；串口、校准、提示等待均在可取消的后台线程。"""
from __future__ import annotations

from pathlib import Path
import json
import queue
import threading
import time
import tkinter as tk
from tkinter import messagebox, ttk

from .calibration import CancellableSerial, run_calibration
from .core import (BEAM_WIRING, MENU_NOTICE, RAW_NOTICE, TOUCH_WIRING,
                   Evidence, ReadOnlyLink, StageTest, protocol, unique_folder)
from .simulation import SimulatedSerial


class TestbenchApp:
    def __init__(self, root, args, *, enumerate_fn=protocol.list_ports, factory=protocol.open_serial):
        self.root, self.args = root, args
        self.enumerate_fn, self.factory = enumerate_fn, factory
        self.messages = queue.Queue()
        self.worker = None
        self.stop_event, self.cal_cancel = threading.Event(), threading.Event()
        self.poll_gate = threading.Event()
        self.paused, self.pause_confirmed, self.paused_at = False, False, None
        self.stopping, self.closing, self.calibrating = False, False, False
        self.error_seen = False
        self.generation, self.last_frame = 0, None
        self.stage_after = float("inf")
        self.peer = None
        self.prompt_request = None
        self.test = StageTest(args.tool, samples=args.samples)
        self.evidence = Evidence(args.tool, args.simulate)
        self.mode = tk.BooleanVar(value=args.simulate)
        self.port = tk.StringVar(value=args.port or "")
        self.status = tk.StringVar(value="未连接；请选择端口后点击连接，或勾选模拟模式")
        self.badge = tk.StringVar()
        self.instruction = tk.StringVar()
        self.progress = tk.StringVar(value="尚未采集")
        self.live = {key: tk.StringVar(value="—") for key in
                     ("raw", "mask", "fault", "seq", "sample_seq", "valid", "blocked", "ready", "levels", "age")}
        self._build()
        self._mode_changed()
        self._update_stage()
        self.root.protocol("WM_DELETE_WINDOW", self.close)
        self.timer = self.root.after(40, self._drain)

    def _build(self):
        title = "电容触摸测试" if self.args.tool == "touch" else "双光束测试"
        self.root.title("V021 外设测试台 · " + title)
        self.root.geometry("1100x880")
        self.root.minsize(900, 740)
        style = ttk.Style(self.root)
        style.theme_use("clam")
        style.configure("TLabel", font=("Microsoft YaHei UI", 10))
        style.configure("TButton", font=("Microsoft YaHei UI", 10), padding=(9, 6))
        style.configure("Header.TLabel", font=("Microsoft YaHei UI", 18, "bold"))
        style.configure("Warning.TLabel", foreground="#9a3900", background="#fff2d7", padding=9)
        style.configure("Badge.TLabel", foreground="#a52a20", font=("Microsoft YaHei UI", 11, "bold"))
        page = ttk.Frame(self.root, padding=16)
        page.pack(fill="both", expand=True)
        ttk.Label(page, text=title, style="Header.TLabel").pack(anchor="w")
        ttk.Label(page, textvariable=self.badge, style="Badge.TLabel").pack(anchor="w", pady=(3, 8))
        ttk.Label(page, text=MENU_NOTICE, style="Warning.TLabel", wraplength=1020).pack(fill="x", pady=(0, 8))
        wiring = TOUCH_WIRING if self.args.tool == "touch" else BEAM_WIRING + "\n" + RAW_NOTICE
        ttk.Label(page, text=wiring, wraplength=1020).pack(fill="x", pady=(0, 8))
        connection = ttk.Frame(page)
        connection.pack(fill="x")
        ttk.Label(connection, text="串口").pack(side="left")
        self.ports = ttk.Combobox(connection, textvariable=self.port, width=36, state="normal")
        self.ports.pack(side="left", padx=6)
        self.refresh_button = ttk.Button(connection, text="刷新端口", command=self.refresh_ports)
        self.refresh_button.pack(side="left")
        self.mode_check = ttk.Checkbutton(connection, text="模拟（无硬件）", variable=self.mode, command=self._mode_changed)
        self.mode_check.pack(side="left", padx=10)
        self.connect_button = ttk.Button(connection, text="连接并只读检测", command=self.connect)
        self.connect_button.pack(side="left", padx=4)
        self.stop_button = ttk.Button(connection, text="停止检测 / 断开", command=self.stop, state="disabled")
        self.stop_button.pack(side="left", padx=4)
        ttk.Label(page, textvariable=self.status, wraplength=1020, foreground="#174a78").pack(fill="x", pady=8)
        pause_row = ttk.Frame(page)
        pause_row.pack(fill="x", pady=(0, 7))
        self.pause_button = ttk.Button(pause_row, text="停止轮询（保留连接）", command=self.pause_polling, state="disabled")
        self.pause_button.pack(side="left")
        ttk.Label(pause_row, text="停止确认后不再周期发送09；等待1秒，抬手后重新按4/5。",
                  foreground="#9a3900").pack(side="left", padx=10)

        live_box = ttk.LabelFrame(page, text="实时诊断（只有新收到的匹配09帧才更新）", padding=8)
        live_box.pack(fill="x")
        labels = (("raw", "触摸 raw / ADC估算电压"), ("mask", "触摸键mask"),
                  ("fault", "触摸 fault"), ("seq", "请求 seq"), ("sample_seq", "采样 sample_seq"),
                  ("valid", "touch_valid（瞬时脉冲）"), ("blocked", "相对基线 blocked A / B"),
                  ("ready", "光束 ready"), ("levels", "真实电平 raw A / B"), ("age", "最近帧年龄"))
        for i, (key, label) in enumerate(labels):
            column, row = (i % 2) * 2, i // 2
            ttk.Label(live_box, text=label + "：").grid(row=row, column=column, sticky="w", padx=6, pady=3)
            ttk.Label(live_box, textvariable=self.live[key], foreground="#183f64").grid(row=row, column=column+1, sticky="w", padx=6)
        live_box.columnconfigure(1, weight=1)
        live_box.columnconfigure(3, weight=1)
        ttk.Label(page, text="touch_valid=0不表示断线；sample_seq推进不证明ADC正常。未连接/超时后清空旧值。",
                  foreground="#76591d").pack(anchor="w", pady=5)

        stage_box = ttk.LabelFrame(page, text="分阶段引导：做好动作并保持稳定，再点击采集", padding=10)
        stage_box.pack(fill="x", pady=(3, 6))
        ttk.Label(stage_box, textvariable=self.instruction, font=("Microsoft YaHei UI", 12, "bold")).pack(anchor="w")
        buttons = ttk.Frame(stage_box)
        buttons.pack(fill="x", pady=(6, 0))
        self.capture_button = ttk.Button(buttons, text="动作已做好，采集本阶段", command=self.capture, state="disabled")
        self.capture_button.pack(side="left")
        self.reset_button = ttk.Button(buttons, text="重新开始整套测试", command=self.reset_test)
        self.reset_button.pack(side="left", padx=8)
        ttk.Label(buttons, textvariable=self.progress).pack(side="left", padx=8)

        if self.args.tool == "touch":
            cal = ttk.Frame(page)
            cal.pack(fill="x", pady=4)
            self.cal_save_button = ttk.Button(cal, text="16键校准：仅采集保存", command=lambda: self.calibrate(False))
            self.cal_save_button.pack(side="left")
            self.cal_apply_button = ttk.Button(cal, text="16键校准并应用 --apply…", command=lambda: self.calibrate(True))
            self.cal_apply_button.pack(side="left", padx=8)
            ttk.Label(cal, text="先断开检测；仅应用按钮可写运行时中心", foreground="#934000").pack(side="left")
        else:
            self.cal_save_button = self.cal_apply_button = None

        self.cal_prompt = tk.StringVar(value="")
        self.prompt_label = ttk.Label(page, textvariable=self.cal_prompt, wraplength=1020, foreground="#8b3300")
        self.prompt_label.pack(fill="x")
        prompt_controls = ttk.Frame(page)
        prompt_controls.pack(fill="x")
        self.confirm_button = ttk.Button(prompt_controls, text="动作已做好 / 下一步", command=self.confirm_prompt, state="disabled")
        self.confirm_button.pack(side="left")
        self.cancel_cal_button = ttk.Button(prompt_controls, text="取消校准", command=self.cancel_calibration, state="disabled")
        self.cancel_cal_button.pack(side="left", padx=8)
        ttk.Button(prompt_controls, text="导出当前 JSON / CSV / 中文结论", command=self.export).pack(side="right")

        self.log = tk.Text(page, height=6, wrap="word", font=("Microsoft YaHei UI", 10), state="disabled")
        self.log.pack(fill="both", expand=True, pady=(8, 0))
        self.write_log("先点击刷新端口。连接后可观察实时数据；工具不会接管演奏、自动写入或烧录。")

    def write_log(self, text):
        self.log.configure(state="normal")
        self.log.insert("end", time.strftime("%H:%M:%S ") + text + "\n")
        self.log.see("end")
        self.log.configure(state="disabled")

    def _mode_changed(self):
        self.badge.set("【模拟模式】所有数据来自软件替身，不能算硬件通过" if self.mode.get()
                       else "【实机模式】默认只读 115200 / 16字节09 / flag80；不会自动连接")
        if self.mode.get():
            self.port.set("SIMULATED")
        elif self.port.get() == "SIMULATED":
            self.port.set(self.args.port or "")
        self._controls()

    def _controls(self):
        busy = self.worker is not None
        for button in (self.connect_button, self.refresh_button, self.mode_check, self.ports):
            button.configure(state="disabled" if busy else "normal")
        self.stop_button.configure(state="normal" if busy and not self.calibrating and not self.stopping else "disabled")
        can_pause = busy and not self.calibrating and not self.stopping
        can_pause = can_pause and ((self.paused and self.pause_confirmed) or self.last_frame is not None)
        self.pause_button.configure(state="normal" if can_pause else "disabled")
        can_capture = busy and not self.stopping and not self.calibrating and not self.paused and self.last_frame is not None
        can_capture = can_capture and not self.test.active and not self.test.complete and not self.test.aborted
        self.capture_button.configure(state="normal" if can_capture else "disabled")
        self.reset_button.configure(state="disabled" if self.calibrating or self.test.active else "normal")
        for button in (self.cal_save_button, self.cal_apply_button):
            if button:
                button.configure(state="normal" if not busy and not self.mode.get() else "disabled")

    def refresh_ports(self):
        if self.worker is not None:
            return
        if self.mode.get():
            self.ports.configure(values=("SIMULATED",))
            self.port.set("SIMULATED")
            return
        def work():
            try:
                values = [p["port"] + " | " + p["description"] for p in self.enumerate_fn()]
                self.messages.put((self.generation, "ports", values))
            except Exception as exc:
                self.messages.put((self.generation, "port_error", str(exc)))
        threading.Thread(target=work, daemon=True).start()

    def connect(self):
        if self.worker is not None:
            return
        port = self.port.get().split(" | ", 1)[0].strip()
        if not port:
            self.status.set("请选择或输入端口，刷新仅枚举，不会自动连接。")
            return
        if not self.mode.get() and port == "SIMULATED":
            self.status.set("实机模式必须选择实际COM端口。")
            return
        self.generation += 1
        generation = self.generation
        simulated = self.mode.get()
        self.test = StageTest(self.args.tool, samples=self.args.samples)
        self.evidence = Evidence(self.args.tool, simulated, port)
        self.stopping, self.error_seen, self.last_frame = False, False, None
        self.paused, self.pause_confirmed, self.paused_at = False, False, None
        self.pause_button.configure(text="停止轮询（保留连接）")
        self.stop_event = threading.Event()
        self.poll_gate = threading.Event()
        self.poll_gate.set()
        self.peer = SimulatedSerial(raw_capability=self.args.raw_capability, fault=self.args.fault) if simulated else None
        factory = (lambda p, t: self.peer) if simulated else self.factory
        stop_event = self.stop_event
        poll_gate = self.poll_gate
        self.status.set("连接中：等待匹配seq的09诊断；打开端口本身不算连接成功…")
        def work():
            link = ReadOnlyLink(factory, timeout=self.args.timeout, simulated=simulated)
            try:
                requested_at = time.monotonic()
                sample = link.connect(port)
                if not stop_event.is_set():
                    self.messages.put((generation, "sample", (sample, requested_at)))
                while not stop_event.wait(self.args.interval):
                    if not poll_gate.is_set():
                        self.messages.put((generation, "paused", time.monotonic()))
                        while not stop_event.is_set() and not poll_gate.wait(0.05):
                            pass
                        if stop_event.is_set():
                            break
                    if stop_event.is_set() or not poll_gate.is_set():
                        continue
                    requested_at = time.monotonic()
                    sample = link.poll()
                    if not stop_event.is_set():
                        self.messages.put((generation, "sample", (sample, requested_at)))
            except Exception as exc:
                self.messages.put((generation, "error", str(exc)))
            finally:
                link.disconnect()
                self.messages.put((generation, "stopped", None))
        self.worker = threading.Thread(target=work, daemon=True)
        self.worker.start()
        self._update_stage()
        self._controls()

    def _sample(self, sample, requested_at):
        if self.stopping or self.paused:
            return
        self.last_frame = time.monotonic()
        self.evidence.samples.append(sample)
        self.live["raw"].set(f"{sample.raw} / {sample.raw*2.5/4095:.3f} V（估算）")
        self.live["mask"].set(f"0x{sample.key_mask:04X}")
        self.live["fault"].set("1 异常/未标定" if sample.fault else "0")
        self.live["seq"].set(str(sample.seq))
        self.live["sample_seq"].set(str(sample.sample_seq))
        self.live["valid"].set(str(int(sample.touch_valid_pulse)) + "（不作连接状态）")
        self.live["blocked"].set(f"{int(sample.blocked_a)} / {int(sample.blocked_b)}（1=相对基线遮挡）")
        self.live["ready"].set("1 已学习基线" if sample.ready else "0 未就绪")
        self.live["levels"].set(f"{sample.raw_a} / {sample.raw_b}（bit11=1）" if sample.raw_available
                                else "不可用（bit11=0；V021无真实电平）")
        self.status.set(("【模拟】" if sample.simulated else "") + "通信有效：收到匹配09；不代表ADC或外设通过")
        result = self.test.accept(sample) if requested_at >= self.stage_after else None
        if result:
            self.write_log(result["label"] + ("：判据通过" if result["passed"] else "：未通过；" + "；".join(result["reasons"])))
            if self.test.complete:
                self.write_log(self.test.conclusion(simulated=self.mode.get())["summary_zh"])
                self.export()
        self._update_stage()
        self._controls()
        if len(self.evidence.samples) >= 100000:
            self.write_log("达到10万帧保护上限，停止并导出；重新连接可继续新会话。")
            self.stop()

    def _clear_live(self):
        self.last_frame = None
        for value in self.live.values():
            value.set("—（无当前有效数据）")

    def stop(self):
        if self.worker is None or self.calibrating:
            return
        self.stopping = True
        self.paused, self.pause_confirmed, self.paused_at = False, False, None
        self.stop_event.set()
        self._clear_live()
        if not self.test.complete:
            self.test.cancel("用户停止检测；重新开始后再采集")
        self.status.set("正在停止，等待当前事务结束；关闭串口后再等1秒，释放后按4/5。")
        self._controls()

    def pause_polling(self):
        if self.worker is None or self.calibrating or self.stopping:
            return
        if self.paused:
            if not self.pause_confirmed:
                return
            self.paused, self.pause_confirmed, self.paused_at = False, False, None
            self.poll_gate.set()
            self.pause_button.configure(text="停止轮询（保留连接）")
            self.status.set("已恢复只读轮询，等待新的匹配09回复；V021菜单将再次暂停。")
            self.evidence.event("poll_resumed", "用户显式恢复周期09只读查询")
        else:
            self.paused, self.pause_confirmed = True, False
            self.poll_gate.clear()
            self._clear_live()
            if self.test.active:
                self.test.cancel("采集期间停止轮询；请重新开始整套测试")
            self.status.set("正在停止轮询，等待当前事务结束；串口保持打开，确认停止后开始1秒等待。")
        self._update_stage()
        self._controls()

    def capture(self):
        if self.last_frame is None or self.stopping or self.calibrating or self.paused:
            return
        try:
            if self.peer:
                self.peer.set_stage(self.test.stages[self.test.index][0])
            self.test.begin()
            self.evidence.event("stage_begin", self.test.stages[self.test.index][0])
            # 丢弃点击前已排入队列的样本：它们不能成为新阶段证据。
            self.stage_after = time.monotonic()
            self._update_stage()
            self._controls()
        except RuntimeError as exc:
            self.write_log(str(exc))

    def _update_stage(self):
        self.instruction.set(f"{min(self.test.index+1, len(self.test.stages))}/{len(self.test.stages)}  " + self.test.instruction)
        if self.test.active:
            self.progress.set(f"正在采集 {len(self.test.pending)}/{self.test.count}，保持动作")
        elif self.test.aborted:
            self.progress.set("已中断，需要重新开始")
        elif self.test.complete:
            self.progress.set("已完成并自动导出")
        else:
            self.progress.set(f"已完成 {self.test.index}/{len(self.test.stages)} 阶段")

    def reset_test(self):
        if self.calibrating or self.test.active:
            return
        if self.test.results or self.evidence.samples:
            self.export()
        self.test = StageTest(self.args.tool, samples=self.args.samples)
        self.evidence = Evidence(self.args.tool, self.mode.get(), self.evidence.port)
        self._update_stage()
        self._controls()

    def export(self):
        try:
            path = self.evidence.save(self.args.output, self.test)
            self.write_log("已导出：" + str(path.resolve()))
            return path
        except OSError as exc:
            self.write_log("导出失败：" + str(exc))
            return None

    def calibrate(self, apply):
        if self.worker is not None or self.mode.get():
            return
        port = self.port.get().split(" | ", 1)[0].strip()
        if not port:
            self.status.set("校准前请选择实际串口，并停止普通检测。")
            return
        if apply and not messagebox.askokcancel("显式应用运行时校准 --apply",
                "将重新逐键采集全部16键，合格后在全松状态写入16个运行时中心。\n"
                "中途失败可能部分更新；报告会保留ACK数。不会烧录，断电持久性未验证。\n"
                "只有这次明确点击才启用 --apply。确定开始？", parent=self.root):
            return
        try:
            base = unique_folder(self.args.output, "16键校准任务")
        except OSError as exc:
            self.status.set("无法建立校准报告目录：" + str(exc))
            return
        output = base / "采集结果"
        self.calibrating, self.stopping = True, False
        self.cal_cancel = threading.Event()
        self.generation += 1
        generation = self.generation
        cancelled = self.cal_cancel
        self.status.set("16键校准进行中；" + ("启用--apply，完成采集后另有全松确认" if apply else "仅采集保存，不写运行时中心"))
        self.cancel_cal_button.configure(state="normal")
        def prompt(text):
            if cancelled.is_set():
                raise KeyboardInterrupt("用户取消校准")
            event = threading.Event()
            answer = {"confirmed": False}
            self.messages.put((generation, "cal_prompt", (text, event, answer)))
            while not event.wait(0.1):
                if cancelled.is_set():
                    raise KeyboardInterrupt("用户取消校准")
            if not answer["confirmed"] or cancelled.is_set():
                raise KeyboardInterrupt("用户取消校准")
            return ""
        def work():
            audit = {"task": "16键校准", "apply_requested": apply, "port": port,
                     "firmware_programmed": False, "status": "in_progress"}
            try:
                (base / "任务记录.json").write_text(json.dumps(audit, ensure_ascii=False, indent=2), encoding="utf-8")
                code = run_calibration(port, output, apply=apply, prompt=prompt,
                    emit=lambda text: self.messages.put((generation, "log", text)),
                    serial_factory=lambda p, t: CancellableSerial(self.factory(p, t), cancelled))
                audit.update(status="completed", exit_code=code)
                self.messages.put((generation, "log", f"校准结束 exit={code}：{output}"))
            except (Exception, KeyboardInterrupt) as exc:
                audit.update(status="failed_or_cancelled", error=str(exc))
                self.messages.put((generation, "log", "校准失败/取消，不能当作成功：" + str(exc)))
            finally:
                try:
                    (base / "任务记录.json").write_text(json.dumps(audit, ensure_ascii=False, indent=2), encoding="utf-8")
                except OSError as exc:
                    self.messages.put((generation, "log", "任务记录写入失败：" + str(exc)))
                self.messages.put((generation, "cal_done", str(base)))
        self.worker = threading.Thread(target=work, daemon=True)
        self.worker.start()
        self._controls()

    def confirm_prompt(self):
        if self.prompt_request:
            _, event, answer = self.prompt_request
            answer["confirmed"] = True
            event.set()
            self.prompt_request = None
            self.confirm_button.configure(state="disabled")
            self.cal_prompt.set("正在采样 / 校验，请继续保持动作…")

    def cancel_calibration(self):
        self.cal_cancel.set()
        if self.prompt_request:
            self.prompt_request[1].set()
            self.prompt_request = None
        self.confirm_button.configure(state="disabled")
        self.cancel_cal_button.configure(state="disabled")
        self.status.set("正在取消校准；等待串口关闭，已发送写入以报告为准。")

    def _drain(self):
        try:
            while True:
                generation, kind, payload = self.messages.get_nowait()
                if generation != self.generation:
                    continue
                if kind == "sample":
                    self._sample(*payload)
                elif kind == "error":
                    self.error_seen = True
                    self.paused, self.pause_confirmed, self.paused_at = False, False, None
                    self._clear_live()
                    self.test.cancel(payload)
                    self.evidence.event("error", payload)
                    self.status.set("通信失败，已停止；不能当作连接成功：" + payload)
                    self.write_log(self.status.get())
                elif kind == "stopped":
                    self.worker = None
                    self._clear_live()
                    self.evidence.event("disconnected", "串口已关闭")
                    if not self.error_seen:
                        self.status.set("已断开。等待至少1秒，释放全部触摸键，再按4/5并抬手切页。")
                    self.stopping = False
                    self.export()
                    self._update_stage()
                    self._controls()
                elif kind == "paused":
                    if self.paused and not self.stopping:
                        self.pause_confirmed, self.paused_at = True, payload
                        self.pause_button.configure(text="继续只读轮询")
                        self.evidence.event("poll_paused", "当前事务已结束；串口保持打开；不再周期发送09")
                        self.write_log("轮询已停止，串口保持连接；等待1秒，抬手后重新按4/5。")
                        self._controls()
                elif kind == "ports":
                    self.ports.configure(values=payload)
                    self.status.set(f"发现{len(payload)}个端口；请选择正确端口后手动连接。")
                elif kind == "port_error":
                    self.status.set("枚举失败（未连接）：" + payload)
                elif kind == "cal_prompt":
                    self.prompt_request = payload
                    self.cal_prompt.set(payload[0].replace("Enter", "“动作已做好 / 下一步”"))
                    self.confirm_button.configure(state="normal")
                elif kind == "log":
                    self.write_log(payload)
                elif kind == "cal_done":
                    self.worker, self.calibrating, self.prompt_request = None, False, None
                    self.cal_prompt.set("")
                    self.confirm_button.configure(state="disabled")
                    self.cancel_cal_button.configure(state="disabled")
                    self.status.set("校准任务已结束，查看日志/报告判定结果。串口已关；等1秒、释放再按4/5。")
                    self.write_log("校准任务目录：" + payload)
                    self._controls()
        except queue.Empty:
            pass
        if self.last_frame is not None:
            age = time.monotonic() - self.last_frame
            self.live["age"].set(f"{age:.1f} 秒" + ("（等待新帧，不代表持续在线）" if age > 0.5 else ""))
        if self.paused and self.pause_confirmed and not self.stopping:
            remaining = max(0, 1 - (time.monotonic() - self.paused_at))
            self.status.set("已停止轮询，串口保留连接，不再发送周期诊断。" +
                (f"再等待 {remaining:.1f} 秒，随后抬手并重新按4/5。" if remaining > 0 else
                 "1秒已到：请松开全部触摸键，再按4/5并抬手切页。"))
        if self.closing and self.worker is None:
            self.root.destroy()
            return
        self.timer = self.root.after(40, self._drain)

    def close(self):
        self.closing = True
        if self.calibrating:
            self.cancel_calibration()
        elif self.worker is not None:
            self.stop()
        else:
            if self.evidence.samples or self.evidence.events:
                self.export()
            self.root.after_cancel(self.timer)
            self.root.destroy()


def run_gui(args):
    root = tk.Tk()
    app = TestbenchApp(root, args)
    if args.smoke_gui:
        # 验证双击CMD的真实启动链路；不枚举/连接，初始化窗口后自动关闭。
        root.after(400, app.close)
        print("GUI_SMOKE_READY: " + args.tool + "; no serial enumeration/open")
    root.mainloop()
    return 0
