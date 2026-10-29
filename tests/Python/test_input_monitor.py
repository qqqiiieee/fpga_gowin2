import unittest
from types import SimpleNamespace
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'tools'))
from input_monitor import decode

class InputMonitorTests(unittest.TestCase):
    def reply(self,flags):return SimpleNamespace(diag2=flags,touch_raw=123,touch_keys=5,diag3=321)
    def test_each_input_status_bit_is_independent(self):
        names=['touch_valid','touch_fault','midi_seen_or_held','midi_frame_error','beam_a_blocked','beam_b_blocked','midi_overflow','optical_ready','strum_busy']
        for bit,name in enumerate(names):
            with self.subTest(bit=bit):
                value=decode(self.reply(1<<bit))
                self.assertEqual([n for n in names if value[n]],[name])
    def test_reserved_status_bits_do_not_invent_events(self):
        value=decode(self.reply(0xfe00))
        self.assertEqual(sum(isinstance(v,bool) and v for v in value.values()),0)
        self.assertEqual(value['touch_raw'],123);self.assertEqual(value['touch_keys'],'0x0005')
        self.assertEqual(value['touch_sample_sequence'],321)

if __name__=='__main__':unittest.main()
