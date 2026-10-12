"""Offline project-function checks for saved 48 kHz stereo PCM16 captures.

No audio, serial, programming, or network API is used. Time bounds are seconds
relative to the FIRST WAV sample, not relative to evaluator/recorder launch.
Example: --wav capture.wav --profile note --output result.json
         --active-start 1.25 --active-end 5.25

Optional metadata: --run-json file, otherwise <wav>.run.json then run.json.
Recognized timing includes active_start/active_end[_s|_seconds], nested
timing.active.{start,end}_seconds, control_started/ended_relative_seconds,
or audio/capture/record and commands/control
start/end timestamps in the same monotonic (seconds/ns) or wall-clock domain.
Process timestamps give coarse bounds; they cannot locate UART handshake,
individual note packets, ADC switching, or control smoothing precisely.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime
import json
import math
from pathlib import Path
import wave

import numpy as np


RATE = 48000
MIN_SECONDS = 6.0
# Old PT8211 output clock is 93,750 Hz; it is NOT the WAV acquisition rate.
S6_HZ = 78741 * 93750 / (2 ** 24)
PROFILES = ("note", "volume", "pitch", "kick", "snare", "zero", "chord")
TINY = 1e-30
GAIN_ASSUMPTION = "baseline 比较假设接线、输入模式和采集增益相同，且 AGC 未改变增益；该假设尚未确认。"
CALIBRATION_NOTICE = "deviceInput calibration 未确认：ADC 输入模式、采集增益与 AGC 未标定。"


def check(status, metrics=None, limits=None, reason=None, **extra):
    result = {"status": status, "metrics": metrics or {}, "limits": limits or {}}
    if reason:
        result["reason"] = reason
    result.update(extra)
    return result


def db_ratio(power, reference):
    return float(10 * np.log10(max(float(power), TINY) / max(float(reference), TINY)))


def dbfs(amplitude):
    return float(20 * np.log10(max(float(amplitude), 1e-15)))


@dataclass
class Audio:
    samples: np.ndarray
    pcm: np.ndarray
    rate: int = RATE

    @property
    def duration(self):
        return len(self.samples) / self.rate


def read_wav(source):
    """Accept a local path or an in-memory binary stream (for synthetic tests)."""
    owned = isinstance(source, (str, Path))
    stream = Path(source).open("rb") if owned else source
    try:
        with wave.open(stream, "rb") as reader:
            info = {"channels": reader.getnchannels(),
                    "sample_width_bytes": reader.getsampwidth(),
                    "sample_rate_hz": reader.getframerate(),
                    "frames": reader.getnframes(),
                    "compression": reader.getcomptype()}
            if info["compression"] != "NONE" or info["sample_width_bytes"] != 2:
                raise ValueError("WAV 必须为无压缩 PCM16。")
            if info["sample_rate_hz"] != RATE or info["channels"] != 2:
                raise ValueError("WAV 必须为 48000 Hz、双声道。")
            data = reader.readframes(info["frames"])
            if len(data) != info["frames"] * 4:
                raise ValueError("WAV 数据被截断或帧长度无效。")
            if info["frames"] < MIN_SECONDS * RATE:
                raise ValueError("WAV 时长必须至少 6 秒。")
        pcm = np.frombuffer(data, dtype="<i2").reshape(-1, 2).copy()
        return Audio(pcm.astype(np.float64) / 32768.0, pcm), info
    finally:
        if owned:
            stream.close()


def levels(samples):
    dc = np.mean(samples, axis=0)
    rms = float(np.sqrt(np.mean(samples ** 2)))
    ac_rms = float(np.sqrt(np.mean((samples - dc) ** 2)))
    peak = float(np.max(np.abs(samples)))
    return {"rms": rms, "rms_dbfs": dbfs(rms), "ac_rms": ac_rms,
            "ac_rms_dbfs": dbfs(ac_rms), "peak": peak,
            "peak_dbfs": dbfs(peak), "dc_per_channel": dc.tolist(),
            "rms_per_channel": np.sqrt(np.mean(samples ** 2, axis=0)).tolist()}


def spectrum(samples):
    """Hann PSD, averaging CHANNEL POWER to avoid stereo phase cancellation."""
    count = len(samples)
    window = np.hanning(count)
    transform = np.fft.rfft((samples - np.mean(samples, axis=0)) * window[:, None], axis=0)
    psd = np.mean(np.abs(transform) ** 2, axis=1) / (RATE * np.sum(window ** 2))
    psd[1:-1] *= 2
    return np.fft.rfftfreq(count, 1 / RATE), psd


def interpolated_frequency(freqs, psd, index):
    if index <= 0 or index >= len(psd) - 1:
        return float(freqs[index])
    a, b, c = np.log(np.maximum(psd[index - 1:index + 2], TINY))
    denominator = a - 2 * b + c
    offset = 0.0 if abs(denominator) < 1e-12 else float(np.clip(.5 * (a - c) / denominator, -.5, .5))
    return float(freqs[index] + offset * (freqs[1] - freqs[0]))


def peak_metrics(freqs, psd, expected, targets=()):
    band = np.flatnonzero(np.abs(freqs - expected) <= expected * .01)
    metrics = {"expected_hz": float(expected), "search_band_hz": [expected * .99, expected * 1.01],
               "frequency_hz": None, "error_percent": None, "prominence_db": None}
    if not len(band):
        return metrics
    index = int(band[np.argmax(psd[band])])
    # A candidate must be a local maximum, not the edge of a different tone.
    local_maximum = 0 < index < len(psd) - 1 and psd[index] >= max(psd[index - 1], psd[index + 1])
    local = np.abs(freqs - expected) <= max(30.0, expected * .1)
    for target in tuple(targets) + (expected,):
        local &= np.abs(freqs - target) > max(5.0, 3 * (freqs[1] - freqs[0]))
    noise_psd = float(np.median(psd[local])) if np.any(local) else float(np.median(psd[1:]))
    frequency = interpolated_frequency(freqs, psd, index)
    metrics.update(frequency_hz=frequency,
                   error_percent=abs(frequency - expected) / expected * 100,
                   prominence_db=db_ratio(psd[index], noise_psd),
                   local_median_psd=noise_psd, peak_psd=float(psd[index]),
                   is_local_maximum=bool(local_maximum), fft_bin_hz=float(freqs[1] - freqs[0]))
    return metrics


def slice_seconds(audio, start, end):
    return audio.samples[int(round(start * RATE)):int(round(end * RATE))]


def finite_number(value):
    if isinstance(value, bool):
        raise ValueError("boolean is not a timestamp")
    number = float(value)
    if not math.isfinite(number):
        raise ValueError("timestamp must be finite")
    return number


def metadata_timing(metadata):
    """Use named clocks only; never subtract a wall clock from monotonic time."""
    if not isinstance(metadata, dict):
        return None
    timing = metadata.get("timing", {})
    roots = [("timing", timing), ("run", metadata)]
    for label, root in roots:
        if not isinstance(root, dict):
            continue
        for suffix in ("_seconds", "_s", ""):
            start, end = root.get("active_start" + suffix), root.get("active_end" + suffix)
            if start is not None and end is not None:
                return finite_number(start), finite_number(end), label + ".active_relative_seconds"
        active = root.get("active", {})
        if isinstance(active, dict):
            for suffix in ("_seconds", "_s"):
                if "start" + suffix in active and "end" + suffix in active:
                    return (finite_number(active["start" + suffix]),
                            finite_number(active["end" + suffix]), label + ".active_relative_seconds")
        # Recorder-ready metadata records these offsets against actual
        # capture start, which is preferable to the older process-launch wall
        # timestamp. These still bound a command process, not stable packets.
        for prefix in ("control", "command", "commands", "serial"):
            for first, last in (("started", "ended"), ("start", "end")):
                start_key = prefix + "_" + first + "_relative_seconds"
                end_key = prefix + "_" + last + "_relative_seconds"
                if start_key in root and end_key in root:
                    return (finite_number(root[start_key]), finite_number(root[end_key]),
                            label + "." + prefix + "_relative_seconds")

    audio_names = ("wav", "audio", "capture", "record", "recording", "audio_capture")
    command_names = ("commands", "command", "control", "serial", "serial_commands")

    def stamps(root, names, endpoint, clock):
        suffixes = {"monotonic": ("_monotonic", "_monotonic_s", "_monotonic_seconds"),
                    "monotonic_ns": ("_monotonic_ns",),
                    "wall": ("_wall", "_wall_clock", "_wall_time", "_timestamp", "_local", "_utc")}[clock]
        variants = (endpoint, "started" if endpoint == "start" else "ended")
        for name in names:
            nested = root.get(name, {})
            for variant in variants:
                for suffix in suffixes:
                    if isinstance(nested, dict) and variant + suffix in nested:
                        return nested[variant + suffix], name + "." + variant + suffix
                    key = name + "_" + variant + suffix
                    if key in root:
                        return root[key], key
            if clock == "wall" and isinstance(nested, dict):
                for variant in variants:
                    if variant in nested and isinstance(nested[variant], str):
                        return nested[variant], name + "." + variant
        return None

    def clock_value(value, clock):
        if clock == "wall" and isinstance(value, str):
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
            if parsed.tzinfo is None:
                raise ValueError("墙钟时间必须注明时区。")
            return parsed.timestamp()
        return finite_number(value) / (1e9 if clock == "monotonic_ns" else 1)

    # Prefer monotonic clocks, then explicitly time-zoned wall clocks.
    for clock in ("monotonic", "monotonic_ns", "wall"):
        for label, root in roots:
            if not isinstance(root, dict):
                continue
            audio_start = stamps(root, audio_names, "start", clock)
            if audio_start is None and isinstance(root.get("capture_ready"), dict):
                audio_start = stamps(root["capture_ready"], audio_names, "start", clock)
                if audio_start:
                    audio_start = audio_start[0], "capture_ready." + audio_start[1]
            command_start = stamps(root, command_names, "start", clock)
            command_end = stamps(root, command_names, "end", clock)
            # Older run_remote_capture metadata uses recorder PROCESS launch.
            if audio_start is None and clock == "wall" and "started_local" in root:
                audio_start = root["started_local"], "started_local(process_launch)"
            if audio_start and command_start and command_end:
                origin = clock_value(audio_start[0], clock)
                return (clock_value(command_start[0], clock) - origin,
                        clock_value(command_end[0], clock) - origin,
                        label + "." + clock + ":" + audio_start[1])
    return None


def load_metadata(wav, run_json=None):
    if run_json is not None:
        candidates = [Path(run_json)]
    elif isinstance(wav, (str, Path)):
        path = Path(wav)
        candidates = [path.with_suffix(".run.json"), path.parent / "run.json"]
    else:
        return {}, None, None
    for path in candidates:
        if path.is_file():
            try:
                value = json.loads(path.read_text(encoding="utf-8-sig"))
                if not isinstance(value, dict):
                    raise ValueError("run metadata must be a JSON object")
                return value, str(path), None
            except (OSError, ValueError) as exc:
                return {}, str(path), str(exc)
    return {}, str(candidates[0]) if run_json else None, "未找到指定 run metadata。" if run_json else None


def resolve_window(audio, metadata, start, end):
    limits = {"units": "seconds_relative_to_first_wav_sample", "minimum_window_seconds": .5,
              "timing_precision": "coarse", "recommended_steady_window_seconds": [1.25, 5.25],
              "note": "时间边界未校准；UART 握手、30 ms 延迟、ADC 切换和控制平滑会移动实际信号边界。"}
    if (start is None) != (end is None):
        return None, check("fail", limits=limits, reason="active_start 和 active_end 必须同时提供。")
    try:
        found = ((finite_number(start), finite_number(end), "explicit_cli")
                 if start is not None else metadata_timing(metadata))
    except (ValueError, TypeError, OverflowError) as exc:
        return None, check("inconclusive", limits=limits, reason="无法解析 timing：" + str(exc))
    if found is None:
        return None, check("inconclusive", limits=limits,
                           reason="缺少可用 timing，请提供相对 WAV 起点的 active_start/active_end。")
    start, end, origin = found
    metrics = {"active_start_seconds": start, "active_end_seconds": end, "source": origin}
    if not (0 <= start < end <= audio.duration) or end - start < .5:
        return None, check("fail", metrics, limits, "活动窗口越界、颠倒或不足 0.5 秒。")
    return (start, end), check("pass", metrics, limits)


def steady_blocks(start, end):
    # The explicit recommended window is already trimmed; do not erase the
    # small 433->447 Hz sweep with a second large onset/offset trim.
    guard = .025
    width = min(1.0, (end - start - 2 * guard) / 3)
    center = (start + end) / 2
    return ((start + guard, start + guard + width),
            (end - guard - width, end - guard),
            (center - min(2.0, end - start - 2 * guard) / 2,
             center + min(2.0, end - start - 2 * guard) / 2))


def expected_tones(audio, bounds, targets, reference_power):
    block = steady_blocks(*bounds)[2]
    samples = slice_seconds(audio, *block)
    measurement = levels(samples)
    energy_db = None if reference_power is None else db_ratio(measurement["ac_rms"] ** 2, reference_power)
    freqs, psd = spectrum(samples)
    peaks = []
    limits = {"search_tolerance_percent": 1.0, "max_frequency_error_percent_exclusive": .5,
              "minimum_local_psd_prominence_db": 12.0, "minimum_energy_rise_db": 10.0,
              "window": "Hann", "pitch_rule": "逐个预期基频检查；全频谱最大峰不能作为音高或全部和弦依据。"}
    for expected in targets:
        metrics = peak_metrics(freqs, psd, expected, targets)
        metrics.update(energy_rise_db=energy_db, steady_window_seconds=list(block))
        significant = (metrics.get("is_local_maximum", False)
                       and metrics["prominence_db"] is not None and metrics["prominence_db"] >= 12)
        if reference_power is None:
            status, reason = "inconclusive", "缺少活动前底噪，不能验证信号能量提升。"
        elif not significant:
            status, reason = "fail", "未观察到显著的预期基频；信号来源无法确定。"
        elif energy_db < 10:
            status, reason = "inconclusive", "目标附近有峰，但能量提升不足 10 dB。"
        elif metrics["error_percent"] >= .5:
            status, reason = "fail", "预期附近的显著峰频率误差不小于 0.5%。"
        else:
            status, reason = "pass", "预期基频及能量提升达到项目参考阈值。"
        peaks.append(check(status, metrics, limits, reason, source_unknown=not significant))
    statuses = [p["status"] for p in peaks]
    status = "fail" if "fail" in statuses else "inconclusive" if "inconclusive" in statuses else "pass"
    return check(status, {"peaks": peaks, "steady_levels": measurement, "energy_rise_db": energy_db}, limits,
                 "逐个预期峰检查完成。", source_unknown=any(p["source_unknown"] for p in peaks))


def volume_check(audio, bounds, reference_power):
    early, late, _ = steady_blocks(*bounds)
    before, after = levels(slice_seconds(audio, *early)), levels(slice_seconds(audio, *late))
    change = db_ratio(after["ac_rms"] ** 2, before["ac_rms"] ** 2)
    snrs = [None, None] if reference_power is None else [db_ratio(x["ac_rms"] ** 2, reference_power) for x in (before, after)]
    metrics = {"early_window_seconds": list(early), "late_window_seconds": list(late),
               "early_levels": before, "late_levels": after,
               "rms_increase_db": change, "block_snr_db": snrs}
    limits = {"minimum_rms_increase_db": 6.0, "minimum_each_block_snr_db": 10.0,
              "note": "参考功能检查；采集增益和 AGC 未确认，幅度不足不能直接判定 FPGA 音量功能失败。"}
    if reference_power is None or min(snrs) < 10:
        return check("inconclusive", metrics, limits, "缺少底噪参考或早晚块信噪比不足。")
    if change < 6:
        return check("inconclusive", metrics, limits, "RMS 上升不足 6 dB；增益或 AGC 可能掩盖音量变化。")
    return check("pass", metrics, limits, "早晚稳态块 RMS 上升至少 6 dB。")


def pitch_check(audio, bounds, reference_power, expected, pitch_range, direction):
    frame_size, hop = 12000, 2400  # 250 ms Hann, 50 ms hop; 4 Hz bins + interpolation.
    samples = slice_seconds(audio, *bounds)
    track = []
    anchor = expected
    for offset in range(0, len(samples) - frame_size + 1, hop):
        block = samples[offset:offset + frame_size]
        power = levels(block)["ac_rms"] ** 2
        snr = None if reference_power is None else db_ratio(power, reference_power)
        freqs, psd = spectrum(block)
        candidates = np.flatnonzero((freqs[1:-1] >= pitch_range[0]) & (freqs[1:-1] <= pitch_range[1])
                                    & (psd[1:-1] >= psd[:-2]) & (psd[1:-1] > psd[2:])) + 1
        accepted = []
        for index in candidates:
            frequency = interpolated_frequency(freqs, psd, int(index))
            local = (np.abs(freqs - frequency) < 50) & (np.abs(freqs - frequency) > 12)
            floor = float(np.median(psd[local])) if np.any(local) else TINY
            prominence = db_ratio(psd[index], floor)
            if (prominence >= 12 and abs(frequency - anchor) <= max(30.0, expected * .08)
                    and pitch_range[0] <= frequency <= pitch_range[1]):
                accepted.append((abs(frequency - anchor), frequency, prominence))
        # Follow the known S6 fundamental continuously; neither highest
        # frequency nor the largest all-band peak is a pitch estimator here.
        chosen = min(accepted) if accepted and snr is not None and snr >= 10 else None
        if chosen:
            anchor = chosen[1]
        track.append({"time_seconds": bounds[0] + (offset + frame_size / 2) / RATE,
                      "frequency_hz": chosen[1] if chosen else None,
                      "prominence_db": chosen[2] if chosen else None, "snr_db": snr})
    count = len(track)
    valid = [item for item in track if item["frequency_hz"] is not None]
    endpoint_count = min(3, count)  # 150 ms endpoint groups retain a ~14 Hz sweep.
    early = [x["frequency_hz"] for x in track[:endpoint_count] if x["frequency_hz"] is not None]
    late = [x["frequency_hz"] for x in track[-endpoint_count:] if x["frequency_hz"] is not None] if count else []
    first = float(np.median(early)) if early else None
    last = float(np.median(late)) if late else None
    change = last - first if first is not None and last is not None else None
    signed_change = change if direction == "up" else -change if change is not None else None
    metrics = {"expected_anchor_hz": expected, "tracking_range_hz": list(pitch_range),
               "first_hz": first, "last_hz": last, "change_hz": change,
               "direction": direction, "valid_frames": len(valid), "total_frames": count,
               "valid_fraction": len(valid) / count if count else 0.0, "track": track}
    limits = {"minimum_change_hz_exclusive": 10.0, "minimum_frame_snr_db": 10.0,
              "minimum_local_psd_prominence_db": 12.0, "minimum_valid_fraction": .7,
              "stft_frame_seconds": .25, "stft_hop_seconds": .05,
              "note": "旧固件 pitch 96→160 对 S6 约为 433→447 Hz；仅跟踪已知基频，避免高次谐波替代。"}
    if not count or len(valid) / count < .7 or len(early) < min(2, endpoint_count) or len(late) < min(2, endpoint_count):
        return check("inconclusive", metrics, limits, "低 SNR、基频缺失或首尾跟踪不足，无法判断音高变化。")
    if signed_change is None or signed_change <= 10:
        return check("fail", metrics, limits, "可靠基频轨迹的变化方向或首尾大于 10 Hz 条件未满足。")
    return check("pass", metrics, limits, "已知基频变化方向正确且首尾变化大于 10 Hz。")


def transient_check(audio, bounds, reference_power):
    samples = slice_seconds(audio, *bounds)
    size, hop = 960, 480  # 20 ms RMS envelope, not a single-sample peak.
    envelope = np.asarray([levels(samples[i:i + size])["ac_rms"]
                           for i in range(0, len(samples) - size + 1, hop)])
    limits = {"envelope_window_seconds": .02, "envelope_hop_seconds": .01,
              "minimum_envelope_rise_db_exclusive": 10.0,
              "minimum_consecutive_above_threshold_frames": 3,
              "minimum_decay_db": 6.0, "minimum_tail_seconds": .25,
              "single_pulse": True, "fixed_fundamental_required": False}
    metrics = {"peak_envelope_rms": float(np.max(envelope)) if len(envelope) else 0.0}
    if reference_power is None or not len(envelope):
        return check("inconclusive", metrics, limits, "缺少活动前底噪或可用包络。")
    peak_index = int(np.argmax(envelope))
    peak_rise = db_ratio(envelope[peak_index] ** 2, reference_power)
    above = envelope ** 2 > reference_power * 10
    groups, current = [], []
    for index, flag in enumerate(above):
        if flag:
            current.append(index)
        elif current:
            groups.append(current)
            current = []
    if current:
        groups.append(current)
    significant_groups = [g for g in groups if len(g) >= 3]
    # Merge short gaps from envelope oscillation, but count separated strikes.
    bursts = []
    for group in significant_groups:
        if bursts and (group[0] - bursts[-1][-1]) * hop / RATE < .1:
            bursts[-1].extend(group)
        else:
            bursts.append(group[:])
    tail_start = peak_index + int(.3 * RATE / hop)
    tail_end = min(len(envelope), peak_index + int(.8 * RATE / hop))
    tail = envelope[tail_start:tail_end]
    tail_rms = float(np.median(tail)) if len(tail) else None
    decay = db_ratio(envelope[peak_index] ** 2, tail_rms ** 2) if tail_rms is not None else None
    metrics.update(peak_time_seconds=bounds[0] + (peak_index * hop + size / 2) / RATE,
                   envelope_rise_db=peak_rise, significant_bursts=len(bursts),
                   above_threshold_frames=int(np.count_nonzero(above)),
                   tail_envelope_rms=tail_rms, decay_db=decay,
                   tail_duration_seconds=len(tail) * hop / RATE)
    if peak_rise <= 10:
        return check("inconclusive", metrics, limits, "包络未超过底噪 10 dB，无法判断打击响应。", source_unknown=True)
    if not significant_groups:
        return check("fail", metrics, limits, "只有极短尖峰，没有持续至少三个包络帧的打击响应。")
    if len(bursts) != 1:
        return check("fail", metrics, limits, "检测到多个分离的显著脉冲，未满足单脉冲参考条件。")
    if len(tail) * hop / RATE < .25:
        return check("inconclusive", metrics, limits, "峰后尾部不足，无法验证衰减。")
    if decay is None or decay < 6:
        return check("fail", metrics, limits, "峰后包络未明显衰减。")
    return check("pass", metrics, limits, "单次持续包络显著高于底噪，并随后衰减。")


def zero_check(audio, bounds):
    start, end = bounds if bounds else (0.0, audio.duration)
    samples = slice_seconds(audio, start, end)
    # Average several Hann PSDs: zero observation is not a pitch test.
    count = min(48000, len(samples))
    transforms = [spectrum(samples[i:i + count]) for i in range(0, len(samples) - count + 1, count)]
    freqs = transforms[0][0]
    psd = np.mean([x[1] for x in transforms], axis=0)
    candidates = np.flatnonzero((freqs[1:-1] >= 20) & (freqs[1:-1] <= 20000)
                                & (psd[1:-1] > psd[:-2]) & (psd[1:-1] >= psd[2:])) + 1
    strongest = sorted(candidates, key=lambda i: float(psd[i]), reverse=True)[:5]
    peaks = []
    for index in strongest:
        frequency = interpolated_frequency(freqs, psd, int(index))
        local = (np.abs(freqs - frequency) <= 30) & (np.abs(freqs - frequency) > 5)
        prominence = db_ratio(psd[index], np.median(psd[local]))
        peaks.append({"frequency_hz": frequency, "psd": float(psd[index]),
                      "local_prominence_db": prominence, "narrow_peak_observed": prominence >= 12})
    return check("inconclusive", {"window_seconds": [start, end], **levels(samples), "spectral_peaks": peaks},
                 {"digital_zero_verifiable_from_analog_wav": False,
                  "narrow_peak_observation_db": 12.0,
                  "note": "DAC 后及采集前可有模拟噪声；非零 RMS 或窄谱不能归因于软件，也不能证明数字零失败。"},
                 "仅量化模拟录音残余；不能由 WAV 单独确认板内数字零或噪声来源。")


def summary_detail(profile, result):
    metrics = result["metrics"]
    if profile in ("note", "chord") and "peaks" in metrics:
        observations = []
        for peak in metrics["peaks"]:
            measured = peak["metrics"]["frequency_hz"]
            label = {"pass": "通过", "fail": "未通过", "inconclusive": "无法确定"}[peak["status"]]
            text = f"目标 {peak['metrics']['expected_hz']:.3f} Hz {label}"
            if peak["status"] == "pass" and measured is not None:
                text += f"（测得 {measured:.3f} Hz）"
            observations.append(text)
        if result.get("source_unknown"):
            observations.append("source_unknown：无法区分未接入与 FPGA 未发出预期声音")
        return "；".join(observations)
    if profile == "volume" and "rms_increase_db" in metrics:
        return f"早晚 RMS 变化 {metrics['rms_increase_db']:.2f} dB；采集增益与 AGC 仍需确认"
    if profile == "pitch" and metrics.get("change_hz") is not None:
        return f"基频 {metrics['first_hz']:.2f}→{metrics['last_hz']:.2f} Hz，变化 {metrics['change_hz']:.2f} Hz"
    if profile in ("kick", "snare") and metrics.get("decay_db") is not None:
        return f"包络提升 {metrics['envelope_rise_db']:.2f} dB，峰后衰减 {metrics['decay_db']:.2f} dB；{result['reason']}"
    if profile == "zero" and "rms_dbfs" in metrics:
        return f"RMS {metrics['rms_dbfs']:.2f} dBFS，峰值 {metrics['peak_dbfs']:.2f} dBFS；仅观察模拟残余，无法确认数字零或噪声来源"
    return result.get("reason", "")


def evaluate_capture(wav, profile, *, baseline=None, expected_hz=S6_HZ,
                     expected_hz_list=None, active_start=None, active_end=None,
                     metadata=None, run_json=None, pitch_range=None, pitch_direction="up"):
    """Return a JSON-serializable report; never capture or modify any input."""
    if profile not in PROFILES:
        raise ValueError("unknown profile")
    targets = list(expected_hz_list) if expected_hz_list is not None else [261.626, S6_HZ]
    expected_hz = finite_number(expected_hz)
    if expected_hz <= 0 or expected_hz >= RATE / 2 or not targets:
        raise ValueError("expected frequencies must be positive and below Nyquist")
    targets = [finite_number(x) for x in targets]
    if any(x <= 0 or x >= RATE / 2 for x in targets):
        raise ValueError("expected frequencies must be positive and below Nyquist")
    pitch_range = tuple(pitch_range or (expected_hz - 20, expected_hz + 20))
    pitch_range = tuple(finite_number(x) for x in pitch_range)
    if len(pitch_range) != 2 or not 0 < pitch_range[0] < pitch_range[1] < RATE / 2:
        raise ValueError("invalid pitch range")
    if pitch_direction not in ("up", "down"):
        raise ValueError("invalid pitch direction")
    report = {"schema_version": 1, "profile": profile,
              "scope": "FPGA 乐器虚拟输入与真实音频路径的项目功能验收参考（离线）",
              "wav": str(wav) if isinstance(wav, (str, Path)) else "in_memory_pcm16",
              "status": "inconclusive", "summary": "", "checks": {},
              "notices": [CALIBRATION_NOTICE, "PCM 没有数字满量程样本也不能排除模拟削顶。"],
              "assumptions": ["显式时间窗是粗略边界，不能证明串口命令已被 FPGA 接收。"]}
    checks = report["checks"]
    format_limits = {"encoding": "PCM16", "sample_rate_hz": RATE, "channels": 2,
                     "minimum_duration_seconds": MIN_SECONDS, "nominal_capture_seconds": 8.0}
    try:
        audio, info = read_wav(wav)
    except (OSError, ValueError, wave.Error, EOFError) as exc:
        checks["wav_format"] = check("fail", {}, format_limits, str(exc))
        checks["pcm_full_scale"] = check("inconclusive", limits={"maximum_count": 0}, reason="WAV 无效，无法计数。")
        report.update(status="fail", summary=profile + "：WAV 无效；" + str(exc), acceptance_checks=["wav_format"])
        return report
    checks["wav_format"] = check("pass", {**info, "duration_seconds": audio.duration}, format_limits)
    endpoints = (audio.pcm == 32767) | (audio.pcm == -32768)
    full_scale_count = int(np.count_nonzero(endpoints))
    checks["pcm_full_scale"] = check("fail" if full_scale_count else "pass",
        {"count": full_scale_count, "positive_count": int(np.count_nonzero(audio.pcm == 32767)),
         "negative_count": int(np.count_nonzero(audio.pcm == -32768)),
         "frames_with_full_scale": int(np.count_nonzero(np.any(endpoints, axis=1))),
         "per_channel_count": np.count_nonzero(endpoints, axis=0).tolist()},
        {"maximum_count": 0, "sample_endpoints": [-32768, 32767],
         "note": "记录 PCM 端点命中；无数字满量程不排除模拟链路削顶。"})
    if metadata is None:
        metadata, metadata_path, metadata_error = load_metadata(wav, run_json)
    else:
        metadata_path, metadata_error = None, None
    report["run_metadata"] = {"path": metadata_path, "error": metadata_error}
    if metadata_error:
        report["notices"].append("run metadata 无法使用：" + metadata_error)
    checks["capture_calibration"] = check("inconclusive",
        {"deviceInput_calibration_confirmed": False, "metadata_calibration": metadata.get("calibration") if isinstance(metadata, dict) else None},
        {"adc_input_mode_calibrated": False, "gain_calibrated": False, "agc_calibrated": False}, CALIBRATION_NOTICE)
    bounds, checks["timing"] = resolve_window(audio, metadata, active_start, active_end)
    baseline_audio = None
    if baseline is not None:
        report["assumptions"].append(GAIN_ASSUMPTION)
        try:
            baseline_audio, baseline_info = read_wav(baseline)
            checks["baseline_format"] = check("pass", {**baseline_info, "duration_seconds": baseline_audio.duration}, format_limits)
            checks["baseline_format"]["metrics"]["full_scale_count"] = int(np.count_nonzero((baseline_audio.pcm == 32767) | (baseline_audio.pcm == -32768)))
        except (OSError, ValueError, wave.Error, EOFError) as exc:
            checks["baseline_format"] = check("fail", limits=format_limits, reason=str(exc))
            report["notices"].append("baseline 无效，不能用于辅助比较。")
    reference_power = None
    reference = {}
    if bounds and bounds[0] - .1 >= .25:
        # A steady-window start (e.g. 1.25 s) is later than command onset
        # (e.g. .75 s). Only use the initial quiet block, never ALL samples
        # preceding the steady window, which can already contain the note.
        noise_end = min(.5, bounds[0] - .1)
        measurement = levels(slice_seconds(audio, 0.0, noise_end))
        reference_power = measurement["ac_rms"] ** 2
        reference = {"source": "pre_active_wav", "window_seconds": [0.0, noise_end], **measurement}
    elif baseline_audio is not None and checks["baseline_format"]["metrics"]["full_scale_count"] == 0:
        measurement = levels(baseline_audio.samples)
        reference_power = measurement["ac_rms"] ** 2
        reference = {"source": "baseline_assuming_same_gain", **measurement}
    checks["noise_reference"] = check("pass" if reference_power is not None else "inconclusive", reference,
        {"minimum_pre_active_seconds": .25, "maximum_initial_noise_seconds": .5,
         "pre_active_guard_seconds": .1,
         "note": "假设录音起始至多 0.5 秒尚未发声；稳态起点之前不全是底噪。若起始块已有信号，SNR 仅供参考。"},
        "存在底噪参考。" if reference_power is not None else "缺少足够的活动前窗口和可用 baseline。")
    decisive = ["wav_format", "pcm_full_scale"]
    if profile != "zero":
        decisive.append("timing")
    if bounds:
        if profile == "note" or profile == "chord":
            checks["target_frequency"] = expected_tones(audio, bounds, [expected_hz] if profile == "note" else targets, reference_power)
            key = "target_frequency"
        elif profile == "volume":
            checks["volume_change"] = volume_check(audio, bounds, reference_power)
            key = "volume_change"
        elif profile == "pitch":
            checks["pitch_change"] = pitch_check(audio, bounds, reference_power, expected_hz, pitch_range, pitch_direction)
            key = "pitch_change"
        elif profile in ("kick", "snare"):
            checks["transient_decay"] = transient_check(audio, bounds, reference_power)
            key = "transient_decay"
        else:
            key = "zero_observation"
    else:
        key = {"note": "target_frequency", "chord": "target_frequency", "volume": "volume_change",
               "pitch": "pitch_change", "kick": "transient_decay", "snare": "transient_decay", "zero": "zero_observation"}[profile]
        if profile != "zero":
            checks[key] = check("inconclusive", limits={"minimum_energy_rise_db": 10.0}, reason="缺少有效活动时间窗。")
    if profile == "zero":
        checks[key] = zero_check(audio, bounds)
        if checks["timing"]["status"] == "fail":
            decisive.append("timing")
    decisive.append(key)
    if baseline_audio is not None:
        baseline_levels = levels(baseline_audio.samples)
        active_levels = levels(slice_seconds(audio, *bounds)) if bounds else levels(audio.samples)
        rise = db_ratio(active_levels["ac_rms"] ** 2, baseline_levels["ac_rms"] ** 2)
        usable = checks["baseline_format"]["metrics"]["full_scale_count"] == 0
        # An elevated analog residual cannot be attributed to FPGA software.
        checks["baseline_comparison"] = check("pass" if profile == "zero" and usable and rise <= 3 else "inconclusive",
            {"baseline_levels": baseline_levels, "active_levels": active_levels,
             "rms_difference_db": rise, "same_gain_confirmed": False},
            {"zero_comparison_tolerance_db": 3.0, "assumption": GAIN_ASSUMPTION,
             "note": "仅辅助模拟残余/SNR 比较；不能验证数字零或定位噪声来源。"},
            "模拟残余与 baseline 比较，受未确认增益假设限制。")
    report["acceptance_checks"] = decisive
    statuses = [checks[name]["status"] for name in decisive]
    report["status"] = "fail" if "fail" in statuses else "inconclusive" if "inconclusive" in statuses else "pass"
    label = {"pass": "通过", "fail": "未通过", "inconclusive": "无法确定"}[report["status"]]
    report["summary"] = f"{profile}：{label}；{summary_detail(profile, checks[key])}；PCM 满量程 {full_scale_count} 个；deviceInput calibration 未确认。"
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wav", type=Path, required=True)
    parser.add_argument("--profile", choices=PROFILES, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--run-json", type=Path)
    parser.add_argument("--expected-hz", type=float, default=S6_HZ)
    parser.add_argument("--expected-hz-list", type=float, nargs="+", help="chord 基频列表，默认 S1 C4 + S6 A4")
    parser.add_argument("--active-start", type=float)
    parser.add_argument("--active-end", type=float)
    parser.add_argument("--pitch-range", type=float, nargs=2, metavar=("LOW_HZ", "HIGH_HZ"), help="默认目标 ±20 Hz；也可指定 200 1000")
    parser.add_argument("--pitch-direction", choices=("up", "down"), default="up")
    args = parser.parse_args(argv)
    protected = [args.wav, args.baseline, args.run_json, args.wav.with_suffix(".run.json"), args.wav.parent / "run.json"]
    if any(args.output.resolve() == path.resolve() for path in protected if path is not None):
        parser.error("output 不能覆盖 WAV、baseline 或 run metadata。")
    try:
        result = evaluate_capture(args.wav, args.profile, baseline=args.baseline,
            expected_hz=args.expected_hz, expected_hz_list=args.expected_hz_list,
            active_start=args.active_start, active_end=args.active_end, run_json=args.run_json,
            pitch_range=args.pitch_range, pitch_direction=args.pitch_direction)
    except (TypeError, ValueError) as exc:
        parser.error(str(exc))
    try:
        args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    except OSError as exc:
        parser.error("无法保存结果：" + str(exc))
    print(result["summary"])
    return {"pass": 0, "fail": 1, "inconclusive": 2}[result["status"]]


if __name__ == "__main__":
    raise SystemExit(main())
