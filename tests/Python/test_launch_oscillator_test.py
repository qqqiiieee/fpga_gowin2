"""Offline config forwarding and Shanghai date tests; no hardware calls."""
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timezone, timedelta
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import launch_oscillator_test as launch
import oscillator_test as ot

HERE = Path(__file__).resolve().parent
CONFIG = dict(port='COM8', device_id=0, device_name='麦克风 (USB-Audio)')


class LauncherTests(unittest.TestCase):
    def argv(self, folder, *flags):
        return ['--config', str(folder/'device_config.json'),
                '--manifest', str(folder/'manifest.json'), '--output-dir', str(folder/'results'), *flags]

    def write_config(self, folder, config=CONFIG, encoding='utf-8'):
        path = folder/'device_config.json'
        path.write_text(json.dumps(config, ensure_ascii=False), encoding=encoding)
        return path

    def test_explicit_unicode_config_and_paths_forwarded_return_code_preserved(self):
        with tempfile.TemporaryDirectory(dir=HERE) as tmp:
            folder = Path(tmp); self.write_config(folder)
            argv = self.argv(folder, '--plan-only', '--independence')
            argv[3] = str(folder/'版本信息.json')
            with patch.object(launch.oscillator_test, 'main', return_value=2) as main:
                self.assertEqual(launch.main(argv), 2)
            self.assertEqual(main.call_args.args[0], [
                '--port', 'COM8', '--device-id', '0', '--device-name', CONFIG['device_name'],
                '--manifest', str(folder/'版本信息.json'), '--output-dir', str(folder/'results'),
                '--plan-only', '--independence'])

    def test_no_flags_added_without_request_and_lowercase_port_normalized(self):
        with tempfile.TemporaryDirectory(dir=HERE) as tmp:
            folder = Path(tmp); self.write_config(folder, CONFIG|{'port': 'com8'})
            with patch.object(launch.oscillator_test, 'main', return_value=0) as main:
                self.assertEqual(launch.main(self.argv(folder)), 0)
            forwarded = main.call_args.args[0]
            self.assertEqual(forwarded[1], 'COM8')
            self.assertNotIn('--plan-only', forwarded); self.assertNotIn('--independence', forwarded)

    def test_utf8_bom_and_exact_whitespace_preserved(self):
        with tempfile.TemporaryDirectory(dir=HERE) as tmp:
            name = ' 麦克风 (USB-Audio) '
            path = self.write_config(Path(tmp), CONFIG|{'device_name': name}, encoding='utf-8-sig')
            self.assertEqual(launch.load_config(path)['device_name'], name)

    def test_invalid_schema_and_types_never_call_main(self):
        invalid = [None, [], 'COM8', {}, CONFIG|{'unknown': 1},
                   {key: value for key, value in CONFIG.items() if key != 'device_id'},
                   CONFIG|{'port': 'COM0'}, CONFIG|{'port': 'auto'}, CONFIG|{'port': 8},
                   CONFIG|{'device_id': -1}, CONFIG|{'device_id': True},
                   CONFIG|{'device_id': 0.0}, CONFIG|{'device_id': '0'},
                   CONFIG|{'device_id': 0xffffffff}, CONFIG|{'device_name': 'Realtek'},
                   CONFIG|{'device_name': None}, CONFIG|{'device_name': 'USB-Audio\x00'},
                   CONFIG|{'device_name': 'USB-Audio\n'}]
        with tempfile.TemporaryDirectory(dir=HERE) as tmp:
            folder = Path(tmp)
            for config in invalid:
                with self.subTest(config=config):
                    self.write_config(folder, config)
                    with patch.object(launch.oscillator_test, 'main') as main, redirect_stderr(io.StringIO()):
                        with self.assertRaises(SystemExit) as failure:
                            launch.main(self.argv(folder, '--plan-only'))
                        self.assertEqual(failure.exception.code, 2)
                        main.assert_not_called()

    def test_duplicate_fields_rejected(self):
        with tempfile.TemporaryDirectory(dir=HERE) as tmp:
            folder = Path(tmp)
            (folder/'device_config.json').write_text(
                '{"port":"COM8","port":"COM9","device_id":0,"device_name":"USB-Audio"}', encoding='utf-8')
            with patch.object(launch.oscillator_test, 'main') as main, redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    launch.main(self.argv(folder))
                main.assert_not_called()

    def test_missing_malformed_and_non_utf8_configs_never_call_main(self):
        with tempfile.TemporaryDirectory(dir=HERE) as tmp:
            folder = Path(tmp)
            for content in (None, b'{broken', b'\xff\xfeinvalid'):
                if content is not None:
                    (folder/'device_config.json').write_bytes(content)
                with patch.object(launch.oscillator_test, 'main') as main, redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit):
                        launch.main(self.argv(folder))
                    main.assert_not_called()

    def test_real_plan_reads_config_only_without_enumeration_or_capture(self):
        with tempfile.TemporaryDirectory(dir=HERE) as tmp:
            folder = Path(tmp); self.write_config(folder)
            before = set(folder.iterdir())
            with patch.object(ot, 'acquire') as acquire, patch.object(ot.rc, 'enumerate_ports') as ports, \
                    patch.object(ot, 'audio_inputs') as audio, patch.object(ot.subprocess, 'run') as run, \
                    redirect_stdout(io.StringIO()) as output:
                self.assertEqual(launch.main(self.argv(folder, '--plan-only', '--independence')), 0)
                for mock in (acquire, ports, audio, run):
                    mock.assert_not_called()
            plan = json.loads(output.getvalue())
            self.assertEqual(plan['device_name'], CONFIG['device_name'])
            self.assertEqual(plan['run_folder_timezone'], 'Asia/Shanghai')
            self.assertTrue(plan['independence'])
            self.assertEqual(set(folder.iterdir()), before)

    def test_overrun_failure_exit_and_explicit_reason_forwarded_to_launcher(self):
        with tempfile.TemporaryDirectory(dir=HERE) as tmp:
            folder = Path(tmp); self.write_config(folder)
            (folder/'manifest.json').write_text('{}', encoding='utf-8')
            (folder/'results').mkdir()
            report = dict(success=False, status='fail', release_ack_verified=True,
                          synth_overrun_seen=True, overrun_reason=ot.OVERRUN_REASON)
            with patch.object(ot, 'acquire', return_value=report), redirect_stdout(io.StringIO()) as output:
                self.assertEqual(launch.main(self.argv(folder)), 1)
            summary = json.loads(output.getvalue())
            self.assertTrue(summary['synth_overrun_seen'])
            self.assertIn('synth_overrun', summary['overrun_reason'])
            self.assertTrue(summary['release_ack_verified'])


class ShanghaiDateTests(unittest.TestCase):
    def test_run_folder_uses_shanghai_next_day_independent_of_host_timezone(self):
        instant = datetime(2026, 10, 11, 16, 30, 5, 123456, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory(dir=HERE) as tmp:
            folder = Path(tmp); manifest = folder/'manifest.json'; manifest.write_text('{}', encoding='utf-8')
            argv = ['--port', 'COM8', '--device-id', '0', '--device-name', CONFIG['device_name'],
                    '--manifest', str(manifest), '--output-dir', str(folder)]
            def now(tz=None):
                self.assertIsNotNone(tz)
                self.assertEqual(tz.utcoffset(None), timedelta(hours=8))
                self.assertEqual(tz.tzname(None), 'Asia/Shanghai')
                return instant.astimezone(tz)
            report = dict(success=False, status='inconclusive', release_ack_verified=False)
            with patch.object(ot, 'datetime') as dt, patch.object(ot, 'acquire', return_value=report) as acquire, \
                    redirect_stdout(io.StringIO()):
                dt.now.side_effect = now
                self.assertEqual(ot.main(argv), 2)
            expected = folder/'2026-10-12_003005_123456_oscillators'
            self.assertEqual(acquire.call_args.args[1], expected)
            self.assertTrue((expected/'controller_events.json').is_file())


if __name__ == '__main__':
    unittest.main()
