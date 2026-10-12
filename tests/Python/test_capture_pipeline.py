"""Mock orchestration checks; no real serial/audio/programming devices opened."""
from contextlib import ExitStack, redirect_stdout
from pathlib import Path
import io
import json
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
import wave

import run_remote_capture as capture
import run_test_suite as suite


class PipelineTests(unittest.TestCase):
    def run_capture(self, folder, *, ready=True, release=True, device='麦克风 (USB-Audio)'):
        opened = []
        origin = time.monotonic()
        def popen(command, **kwargs):
            opened.append(command)
            target = Path(command[command.index('--output')+1])
            if ready:
                ready_path = Path(command[command.index('--ready-file')+1])
                ready_path.write_text(json.dumps({'capture_started_monotonic': origin,
                    'capture_started_epoch': time.time(), 'device_id': 0, 'device_name': device}), encoding='utf-8')
                with wave.open(str(target), 'wb') as wav:
                    wav.setnchannels(2);wav.setsampwidth(2);wav.setframerate(48000)
                    wav.writeframes(bytes(48000*8*4))
            return SimpleNamespace(poll=lambda: None if ready else 1,
                communicate=lambda **kw: (b'',b''), returncode=0, kill=lambda: None)
        def run(command, **kwargs):
            journal = Path(command[command.index('--log')+1])
            journal.write_text(json.dumps({'release': {'confirmed': release}, 'packets': [
                {'phase': 'keepalive', 'outcome': 'acknowledged', 'host_monotonic': origin+.8,
                 'request': {'flags': 1}, 'response': {'host_monotonic': origin+.802}},
                {'phase': 'finally_release', 'outcome': 'acknowledged',
                 'host_monotonic': origin+5.8, 'request': {'flags': 0}},
            ]}), encoding='utf-8')
            return SimpleNamespace(returncode=0, stdout=b'', stderr=b'')
        argv=['run_remote_capture.py','--port','COM8','--device-id','0',
              '--profile','note','--output-dir',str(folder)]
        with ExitStack() as stack:
            stack.enter_context(patch('sys.argv', argv))
            stack.enter_context(patch.dict('sys.modules', {'audio_devices':SimpleNamespace(
                enumerate_devices=lambda:[{'id':0,'name':device,'channels':2}])}))
            fake_open=stack.enter_context(patch.object(capture.subprocess,'Popen', side_effect=popen))
            fake_control=stack.enter_context(patch.object(capture.subprocess,'run', side_effect=run))
            stack.enter_context(patch.object(capture.time,'sleep', return_value=None))
            stack.enter_context(redirect_stdout(io.StringIO()))
            failure=None
            try:capture.main()
            except RuntimeError as exc:failure=exc
        return failure, fake_open, fake_control

    def test_confirmed_audio_start_and_release_create_trimmed_timing(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder=Path(tmp)
            failure, _, control=self.run_capture(folder)
            self.assertIsNone(failure)
            self.assertEqual(control.call_count, 1)
            data=json.loads(next(folder.glob('*.run.json')).read_text(encoding='utf-8'))
            self.assertTrue(data['success']);self.assertTrue(data['release_ack_verified'])
            self.assertAlmostEqual(data['timing']['active_start_seconds'],1.302,places=2)
            self.assertAlmostEqual(data['timing']['active_end_seconds'],5.55,places=2)
            self.assertFalse(data['physical_motion'])

    def test_no_recording_ready_never_sends_control(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder=Path(tmp)
            failure, _, control=self.run_capture(folder,ready=False)
            self.assertIsNotNone(failure);control.assert_not_called()
            data=json.loads(next(folder.glob('*.run.json')).read_text(encoding='utf-8'))
            self.assertFalse(data['success'])

    def test_unconfirmed_release_is_not_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder=Path(tmp)
            failure, _, _=self.run_capture(folder,release=False)
            self.assertIsNotNone(failure)
            data=json.loads(next(folder.glob('*.run.json')).read_text(encoding='utf-8'))
            self.assertFalse(data['success']);self.assertFalse(data['release_ack_verified'])

    def test_wrong_audio_input_never_opens_recording_or_serial(self):
        with tempfile.TemporaryDirectory() as tmp:
            failure, audio, control=self.run_capture(Path(tmp),device='Realtek microphone')
            self.assertIsNotNone(failure);audio.assert_not_called();control.assert_not_called()

    def test_suite_plan_only_does_not_access_devices(self):
        with patch.object(suite.subprocess,'run') as run, redirect_stdout(io.StringIO()):
            self.assertEqual(suite.main(['--port','COM8','--device-id','0','--plan-only']),0)
            run.assert_not_called()


if __name__=='__main__':unittest.main()
