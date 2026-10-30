// V032: shared 32-key DISPLAY window, F2..C5 (MIDI41..72, C4=60).
// The user confirmed the physical keyboard's left edge is F2.
// Labels, physical-held slicing and falling-note lanes use this same base.
// The MIDI audio note and the practice scores retain their original pitches.
// Octave shifts change only this base by multiples of 12; rebuild afterwards.
`ifndef INSTRUMENT_PIANO_LAYOUT_VH
`define INSTRUMENT_PIANO_LAYOUT_VH
`define PIANO_BASE_NOTE 41
`define PIANO_LAST_NOTE (`PIANO_BASE_NOTE + 31)
`endif
