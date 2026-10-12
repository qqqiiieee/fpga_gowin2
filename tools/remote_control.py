"""Bounded stdlib-only UART controller (Python 3.11, Windows).
ADC order: A0 pad0, A1 pad1, A2 volume, A3 pitch. Keys S1..S16.
Only present, started FTDIBUS VID_0403 devices using FTDIPORT/FTSER2K are writable.
Preserves DTR/RTS levels; rejects automatic line-control modes.
Disabled restores physical controls (which may sound); --zero is virtual only.
Echoes do not verify finger motion; inactive ADC retains raw uint16 codes.
"""
from __future__ import annotations

import argparse
from collections import OrderedDict, deque
import ctypes as C
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import re
import struct
import sys
import time
MAX_ADC = 26400
ACK_TIMEOUT = .6
KEEPALIVE = .1
FAILURE_LIMIT = 2
INPUT = struct.Struct('<2sBBHB4H')
ACK = struct.Struct('<2sBBBH4H')
STATUS_BITS = {3: 'hw_adc_fault', 4: 'effectiveadc_stale', 5: 'slidersready',
               6: 'ghost', 7: 'overrun'}

def checked_int(value, low, high, name):
    if type(value) is not int or not low <= value <= high:
        raise ValueError(f'{name} must be an integer in {low}..{high}')
    return value

def checksum(data):
    result = 0
    for value in data:
        result ^= value
    return result

def slider_adc(position):
    return round(checked_int(position, 0, 255, 'position') * MAX_ADC / 255)

def encode_packet(seq, flags=0, keys=0, velocity=0, adc=(0, 0, 0, 0)):
    checked_int(seq, 0, 255, 'seq')
    checked_int(flags, 0, 7, 'flags')
    checked_int(keys, 0, 65535, 'keys')
    checked_int(velocity, 0, 255, 'velocity')
    if len(adc) != 4:
        raise ValueError('exactly four ADC values required')
    for value in adc:
        checked_int(value, 0, MAX_ADC, 'ADC')
    body = INPUT.pack(b'\xa5\x5a', seq, flags, keys, velocity, *adc)
    return body + bytes([checksum(body[2:15])])

def parse_ack(packet):
    if len(packet) != 16 or packet[:3] != b'\x5a\xa5\x08':
        raise ValueError('ACK length, magic or version is invalid')
    if checksum(packet[2:15]) != packet[15]:
        raise ValueError('ACK XOR checksum is invalid')
    _, version, seq, flags, keys, *adc = ACK.unpack(packet[:15])
    for value in adc:
        checked_int(value, 0, MAX_ADC if flags & 1 else 65535, 'ACK ADC')
    return dict(version=version, seq=seq, flags=flags, active=bool(flags & 1),
                pcm_zero=bool(flags & 2), park_i2c=bool(flags & 4), keys=keys,
                adc=adc, device_status=flags & 0xf8,
                **{name: bool(flags & (1 << bit)) for bit, name in STATUS_BITS.items()})

class AckStream:
    def __init__(self):
        self.buffer = bytearray()
        self.bad_frames = 0

    def feed(self, data):
        self.buffer.extend(data)
        frames = []
        while self.buffer:
            pos = self.buffer.find(b'\x5a\xa5')
            if pos < 0:
                self.discard_partial()
                break
            del self.buffer[:pos]
            if len(self.buffer) < 16:
                break
            raw = bytes(self.buffer[:16])
            try:
                parsed = parse_ack(raw)
            except ValueError:
                self.bad_frames += 1
                del self.buffer[0]  # Search again, including embedded headers.
            else:
                del self.buffer[:16]
                frames.append((raw, parsed))
        return frames

    def discard_partial(self):
        self.buffer[:] = b'\x5a' if self.buffer.endswith(b'\x5a') else b''

def verified_ftdi(device):
    identity = device.get('instance_id', '').upper()
    text = ' '.join(str(v) for v in device.values()).lower()
    return (bool(re.fullmatch(r'COM[1-9][0-9]*', device.get('port', '')))
            and bool(re.match(r'^FTDIBUS\\VID_0403\+PID_[0-9A-F]{4}\+', identity))
            and device.get('service', '').lower() in ('ftdiport', 'ftser2k')
            and device.get('present_started') is True
            and not any(word in text for word in ('com0com', 'bluetooth', 'bthenum', 'bthmodem')))

def enumerate_ports():
    """Registry enumeration + Configuration Manager presence; never opens COM."""
    if os.name != 'nt':
        raise OSError('serial enumeration requires Windows')
    import winreg as R
    cm = C.WinDLL('cfgmgr32', use_last_error=True)
    cm.CM_Locate_DevNodeW.argtypes = [C.POINTER(C.c_uint32), C.c_wchar_p, C.c_uint32]
    cm.CM_Locate_DevNodeW.restype = C.c_uint32
    cm.CM_Get_DevNode_Status.argtypes = [C.POINTER(C.c_uint32), C.POINTER(C.c_uint32), C.c_uint32, C.c_uint32]
    cm.CM_Get_DevNode_Status.restype = C.c_uint32
    devices = {}
    try:
        with R.OpenKey(R.HKEY_LOCAL_MACHINE, r'HARDWARE\DEVICEMAP\SERIALCOMM') as key:
            for i in range(R.QueryInfoKey(key)[1]):
                name, port, _ = R.EnumValue(key, i)
                if re.fullmatch(r'COM[1-9][0-9]*', port.upper()):
                    devices[port.upper()] = dict(port=port.upper(), name=name, present_started=False)
    except FileNotFoundError:
        pass
    root_path = r'SYSTEM\CurrentControlSet\Enum\FTDIBUS'
    try:
        root = R.OpenKey(R.HKEY_LOCAL_MACHINE, root_path)
    except FileNotFoundError:
        return list(devices.values())
    with root:
        for i in range(R.QueryInfoKey(root)[0]):
            branch_name = R.EnumKey(root, i)
            with R.OpenKey(root, branch_name) as branch:
                for j in range(R.QueryInfoKey(branch)[0]):
                    instance = R.EnumKey(branch, j)
                    with R.OpenKey(branch, instance) as key:
                        try:
                            with R.OpenKey(key, 'Device Parameters') as params:
                                port = R.QueryValueEx(params, 'PortName')[0].upper()
                        except FileNotFoundError:
                            continue
                        def value(name):
                            try:
                                return R.QueryValueEx(key, name)[0]
                            except FileNotFoundError:
                                return ''
                        identity = 'FTDIBUS\\' + branch_name + '\\' + instance
                        node, status, problem = C.c_uint32(), C.c_uint32(), C.c_uint32()
                        present = (cm.CM_Locate_DevNodeW(C.byref(node), identity, 0) == 0
                                   and cm.CM_Get_DevNode_Status(C.byref(status), C.byref(problem), node, 0) == 0
                                   and bool(status.value & 8) and problem.value == 0)
                        devices[port] = dict(port=port, instance_id=identity, service=value('Service'),
                                             name=value('FriendlyName'), hardware_id=value('HardwareID'),
                                             present_started=present)
    return sorted(devices.values(), key=lambda d: d['port'])

class DCB(C.Structure):
    _fields_ = [('length', C.c_uint32), ('baud', C.c_uint32), ('flags', C.c_uint32),
                ('reserved', C.c_uint16), ('xonlim', C.c_uint16), ('xofflim', C.c_uint16),
                ('bytesize', C.c_ubyte), ('parity', C.c_ubyte), ('stopbits', C.c_ubyte),
                ('xon', C.c_char), ('xoff', C.c_char), ('error', C.c_char), ('eof', C.c_char),
                ('event', C.c_char), ('reserved1', C.c_uint16)]

class Timeouts(C.Structure):
    _fields_ = [(name, C.c_uint32) for name in ('interval', 'read_multiplier', 'read_constant',
                                             'write_multiplier', 'write_constant')]

class WindowsSerial:
    def __init__(self, port):
        if os.name != 'nt':
            raise OSError('serial transport requires Windows')
        self.handle = None
        self.api = C.WinDLL('kernel32', use_last_error=True)
        signatures = {'CreateFileW': ([C.c_wchar_p, C.c_uint32, C.c_uint32, C.c_void_p, C.c_uint32, C.c_uint32, C.c_void_p], C.c_void_p),
                      'GetCommState': ([C.c_void_p, C.POINTER(DCB)], C.c_int),
                      'SetCommState': ([C.c_void_p, C.POINTER(DCB)], C.c_int),
                      'SetCommTimeouts': ([C.c_void_p, C.POINTER(Timeouts)], C.c_int),
                      'ReadFile': ([C.c_void_p, C.c_void_p, C.c_uint32, C.POINTER(C.c_uint32), C.c_void_p], C.c_int),
                      'WriteFile': ([C.c_void_p, C.c_void_p, C.c_uint32, C.POINTER(C.c_uint32), C.c_void_p], C.c_int),
                      'CloseHandle': ([C.c_void_p], C.c_int)}
        for name, (args, result) in signatures.items():
            getattr(self.api, name).argtypes, getattr(self.api, name).restype = args, result
        handle = self.api.CreateFileW('\\\\.\\' + port, 0xc0000000, 0, None, 3, 0, None)
        if handle is None or handle == C.c_void_p(-1).value:
            raise C.WinError(C.get_last_error())
        self.handle = handle
        try:
            dcb = DCB()
            dcb.length = C.sizeof(DCB)
            self._check(self.api.GetCommState(handle, C.byref(dcb)))
            if ((dcb.flags >> 4) & 3) > 1 or ((dcb.flags >> 12) & 3) > 1:
                raise OSError('automatic DTR/RTS mode refused; no line-control changes made')
            dcb.baud, dcb.bytesize, dcb.parity, dcb.stopbits = 115200, 8, 0, 0
            dcb.flags = (dcb.flags & ((3 << 4) | (3 << 12))) | 1
            self._check(self.api.SetCommState(handle, C.byref(dcb)))
            self._timeouts(.02)
        except BaseException:
            self.close()
            raise

    @staticmethod
    def _check(ok):
        if not ok:
            raise C.WinError(C.get_last_error())

    def _timeouts(self, seconds):
        timeout = Timeouts(0xffffffff, 0, max(1, math.ceil(seconds * 1000)), 0, 100)
        self._check(self.api.SetCommTimeouts(self.handle, C.byref(timeout)))

    def read(self, count, timeout):
        self._timeouts(timeout)
        buffer, got = C.create_string_buffer(count), C.c_uint32()
        self._check(self.api.ReadFile(self.handle, buffer, count, C.byref(got), None))
        return buffer.raw[:got.value]

    def write(self, data):
        buffer, written = C.create_string_buffer(data), C.c_uint32()
        self._check(self.api.WriteFile(self.handle, buffer, len(data), C.byref(written), None))
        if written.value != len(data):
            raise OSError('partial serial write; stop instead of sending a broken frame again')

    def close(self):
        if self.handle is not None:
            handle, self.handle = self.handle, None
            self._check(self.api.CloseHandle(handle))

class Controller:
    """Multiple in-flight ACKs permit 100 ms keepalive and a 30 ms pad pulse."""
    def __init__(self, serial, clock, sleep, wall):
        self.serial, self.clock, self.sleep, self.wall = serial, clock, sleep, wall
        self.seq, self.handshaken = 0, False
        self.pending, self.records = OrderedDict(), deque(maxlen=100)
        self.stream, self.total, self.ignored = AckStream(), 0, 0
        self.streak, self.failures, self.stopped = 0, 0, False

    def send(self, state, phase):
        flags, keys, velocity, adc = state
        if flags & 1 and not self.handshaken:
            raise RuntimeError('active state forbidden before disabled version-08 ACK')
        packet = encode_packet(self.seq, flags, keys, velocity, adc)
        record = dict(seq=self.seq, phase=phase, host_timestamp=self.wall(),
                      host_monotonic=self.clock(), request_hex=packet.hex(),
                      request=dict(flags=flags, keys=keys, velocity=velocity, adc=list(adc)),
                      response=None, outcome='pending')
        self.records.append(record)
        self.total += 1
        self.seq = (self.seq + 1) & 255
        try:
            self.serial.write(packet)
        except BaseException as exc:
            record.update(outcome='write_error', error=str(exc))
            raise
        record['deadline'] = self.clock() + ACK_TIMEOUT
        self.pending[record['seq']] = record
        return record

    def settle(self):
        while self.pending:
            seq, record = next(iter(self.pending.items()))
            if record['outcome'] == 'pending':
                if self.clock() < record['deadline'] - 1e-9:
                    break
                record.update(outcome='ack_timeout', error='no matching version-08 ACK within 0.6 s')
                self.stream.discard_partial()
            self.pending.pop(seq)
            if record['request']['flags'] & 1:
                if record['outcome'] == 'acknowledged':
                    self.streak = 0
                else:
                    self.failures += 1
                    self.streak += 1
                    self.stopped |= self.streak >= FAILURE_LIMIT

    def pump(self, deadline, until=None, stop=True):
        while True:
            self.settle()
            if stop and self.stopped:
                raise RuntimeError('two consecutive ACK failures; test stopped')
            if until is not None and until['outcome'] != 'pending':
                return
            remaining = deadline - self.clock()
            if remaining <= 1e-9:
                return
            if not self.pending:
                self.sleep(remaining)
                continue
            before = self.clock()
            waiting = [r['deadline'] for r in self.pending.values() if r['outcome'] == 'pending']
            wait = min(.02, remaining, max(1e-9, min(waiting) - before)) if waiting else min(.02, remaining)
            data = self.serial.read(256, wait)
            for raw, ack in self.stream.feed(data):
                record = self.pending.get(ack['seq'])
                if record is None or record['outcome'] != 'pending' or self.clock() > record['deadline'] + 1e-9:
                    self.ignored += 1
                    continue
                record['response'] = dict(hex=raw.hex(), host_timestamp=self.wall(),
                                          host_monotonic=self.clock(), **ack)
                request = record['request']
                if (ack['flags'] & 7 != request['flags'] or
                        (request['flags'] & 1 and (ack['keys'] != request['keys'] or ack['adc'] != request['adc']))):
                    record.update(outcome='echo_mismatch', error='ACK flags or active keys/ADC do not reflect request')
                else:
                    record['outcome'] = 'acknowledged'
            if self.clock() == before and not data:
                self.sleep(min(.001, remaining))

    def exchange(self, state, phase):
        record = self.send(state, phase)
        self.pump(record['deadline'], until=record, stop=False)
        if record['outcome'] != 'acknowledged':
            raise RuntimeError(record.get('error', 'ACK failed'))
        return record['response']

    def drive(self, factory, start, end):
        tick = start
        while tick < end - 1e-9:
            self.pump(tick)
            if self.clock() >= end - 1e-9:
                break
            index = max(0, math.floor((self.clock() - start + 1e-8) / KEEPALIVE))
            self.send(factory(index), 'keepalive')
            tick = start + (index + 1) * KEEPALIVE
            self.pump(min(tick, end))

DISABLED = (0, 0, 0, (0, 0, 0, 0))

def keys_mask(text):
    if not text.strip():
        return 0
    mask = 0
    for item in text.split(','):
        key = checked_int(int(item), 1, 16, 'key S-number')
        mask |= 1 << (key - 1)
    return mask

def parser():
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest='command', required=True)
    commands.add_parser('list', help='enumerate only; never open serial ports')
    for command in ('status', 'play', 'sweep', 'strike', 'release'):
        sub = commands.add_parser(command, help=('disabled handshake, wait 30 ms, read echo; exits remote mode' if command == 'status' else command))
        sub.add_argument('--port', required=True, help='explicit FTDI port, e.g. COM8; no automatic selection')
        sub.add_argument('--log', type=Path, help='JSON log, at most 100 packet records')
        if command in ('status', 'release'):
            continue
        sub.add_argument('--seconds', type=float, default=1.)
        sub.add_argument('--velocity', type=int, default=127)
        sub.add_argument('--volume', type=int, default=255)
        sub.add_argument('--pitch-position', type=int, default=128)
        sub.add_argument('--zero', action='store_true')
        sub.add_argument('--park-i2c', action='store_true')
        if command == 'strike':
            sub.add_argument('--pad', type=int, choices=(0, 1), required=True)
            sub.add_argument('--strength', type=int, default=6000, help='raw ADC amplitude, 0..26400')
        else:
            group = sub.add_mutually_exclusive_group()
            group.add_argument('--keys', default=None, help='S1..S16, e.g. 1,3; empty string means none')
            group.add_argument('--mask', type=lambda s: int(s, 0))
        if command == 'sweep':
            sub.add_argument('--control', choices=('volume', 'pitch'), required=True)
            sub.add_argument('--start', type=int, default=0)
            sub.add_argument('--end', type=int, default=255)
    return root

def validate(args):
    if args.command == 'list':
        return
    args.port = args.port.upper()
    if not re.fullmatch(r'COM[1-9][0-9]*', args.port):
        raise ValueError('explicit --port COMn required')
    if args.log is not None:
        args.log = Path(args.log).expanduser().absolute()
        if not args.log.parent.is_dir() or args.log.is_dir():
            raise ValueError('--log must name a file in an existing directory')
    if args.command in ('status', 'release'):
        return
    minimum = .6 if args.command == 'strike' else .1
    if not math.isfinite(args.seconds) or not minimum <= args.seconds <= 10:
        raise ValueError(f'--seconds must be {minimum}..10 (default 1); strike includes 0.5 s calibration')
    for name in ('velocity', 'volume', 'pitch_position'):
        checked_int(getattr(args, name), 0, 255, name)
    if args.command == 'strike':
        checked_int(args.pad, 0, 1, 'pad')
        checked_int(args.strength, 0, MAX_ADC, 'strength')
        args.key_mask = 0
    else:
        args.key_mask = checked_int(args.mask, 0, 65535, 'mask') if args.mask is not None else keys_mask('1' if args.keys is None else args.keys)
    if args.command == 'sweep':
        for name in ('start', 'end'):
            checked_int(getattr(args, name), 0, 255, name)

def run_command(args, *, enumerate_fn=enumerate_ports, serial_factory=WindowsSerial,
                clock=time.monotonic, sleep=time.sleep,
                wall=lambda: datetime.now(timezone.utc).isoformat(timespec='milliseconds')):
    validate(args)  # All CLI validation precedes enumeration/opening/writing.
    devices = enumerate_fn()
    if args.command == 'list':
        return dict(command='list', devices=[dict(d, verified_ftdi=verified_ftdi(d)) for d in devices], exit_code=0)
    matches = [d for d in devices if d.get('port') == args.port]
    if len(matches) != 1 or not verified_ftdi(matches[0]):
        raise ValueError(f'{args.port} is not a uniquely verified, present FTDI USB serial port; nothing opened')
    result = dict(command=args.command, port=args.port, device=matches[0], exit_code=0, error=None,
                  release=dict(attempted=False, confirmed=False),
                  note='Disabled exits virtual mode and restores physical controls; echoes do not verify finger motion. Physical ADC may be stale.')
    serial = controller = None
    try:
        serial = serial_factory(args.port)
        controller = Controller(serial, clock, sleep, wall)
        result['handshake'] = controller.exchange(DISABLED, 'handshake')
        controller.handshaken = True
        if args.command == 'status':
            sleep(.03)
            result['echo'] = controller.exchange(DISABLED, 'status_after_settle')
        elif args.command not in ('release',):
            flags = 1 | (2 if args.zero else 0) | (4 if args.park_i2c else 0)
            base_adc = (0, 0, slider_adc(args.volume), slider_adc(args.pitch_position))
            base = (flags, args.key_mask, args.velocity, base_adc)
            start, end = clock(), clock() + args.seconds
            if args.command == 'strike':
                controller.drive(lambda _: base, start, start + .5)
                adc = list(base_adc)
                adc[args.pad] = args.strength
                controller.send((flags, 0, args.velocity, tuple(adc)), 'pressure_pulse')
                pulse_start = clock()
                controller.pump(pulse_start + .03)
                controller.send(base, 'pressure_clear')
                result['pressure_pulse_seconds'] = clock() - pulse_start
                controller.drive(lambda _: base, clock() + KEEPALIVE, end)
                controller.pump(end)
            elif args.command == 'sweep':
                count = max(1, math.ceil(args.seconds / KEEPALIVE - 1e-9))
                def swept(index):
                    fraction = min(1., index / (count - 1)) if count > 1 else 1.
                    position = round(args.start + (args.end - args.start) * fraction)
                    adc = list(base_adc)
                    adc[2 if args.control == 'volume' else 3] = slider_adc(position)
                    return flags, args.key_mask, args.velocity, tuple(adc)
                controller.drive(swept, start, end)
            else:
                controller.drive(lambda _: base, start, end)
    except (Exception, KeyboardInterrupt) as exc:
        result.update(exit_code=130 if isinstance(exc, KeyboardInterrupt) else 1,
                      error=str(exc) or 'interrupted')
    finally:
        try:
            if controller is not None:
                result['release']['attempted'] = True
                try:
                    result['release']['echo'] = controller.exchange(DISABLED, 'finally_release')
                    result['release']['confirmed'] = True
                except (Exception, KeyboardInterrupt) as exc:
                    result['release'].update(confirmed=False, error=str(exc) or 'release interrupted',
                                             watchdog_expected_seconds=1,
                                             note='Release NOT confirmed; device 1-second watchdog fallback is expected, not verified.')
                    result['exit_code'] = result['exit_code'] or 1
                if result['release']['confirmed'] and controller.pending:
                    try:
                        controller.pump(max(r['deadline'] for r in controller.pending.values()), stop=False)
                    except (Exception, KeyboardInterrupt) as exc:
                        result.update(error=result['error'] or str(exc) or 'interrupted after release',
                                      exit_code=result['exit_code'] or 1)
        finally:
            if serial is not None:
                try:
                    serial.close()
                except Exception as exc:
                    result.update(close_error=str(exc), exit_code=result['exit_code'] or 1)
    if controller is not None:
        for record in controller.pending.values():
            if record['outcome'] == 'pending':
                record.update(outcome='unconfirmed_at_close', error='ACK not observed before handle close')
        if controller.stopped:
            result.update(exit_code=result['exit_code'] or 1, error=result['error'] or 'two consecutive ACK failures')
        result.update(packets=list(controller.records), packet_count=controller.total,
                      omitted_packets=max(0, controller.total - 100), bad_ack_frames=controller.stream.bad_frames,
                      unmatched_acks=controller.ignored, failed_active_requests=controller.failures)
    if args.log is not None:
        try:
            args.log.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
        except OSError as exc:
            result.update(log_error=str(exc), exit_code=result['exit_code'] or 1)
    return result

def main(argv=None):
    args = parser().parse_args(argv)
    try:
        result = run_command(args)
    except (ValueError, OSError) as exc:
        print(str(exc), file=sys.stderr)
        return 2
    if result.get('release', {}).get('attempted') and not result['release']['confirmed']:
        print('Release NOT confirmed. Device 1-second watchdog fallback is expected, not verified.', file=sys.stderr)
    print(json.dumps({k: v for k, v in result.items() if k != 'packets'}, ensure_ascii=True))
    return result['exit_code']

if __name__ == '__main__':
    raise SystemExit(main())
