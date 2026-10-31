"""Build CE/SOP candidate directly from immutable baseline. Only production write: midi_keyboard.v."""
from pathlib import Path
import hashlib

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
ref = (HERE/'midi_keyboard_before.v').read_bytes()
assert hashlib.sha256(ref).hexdigest() == '08c12d1f527fdb8d2e74dd57df86b8e744931176d47f398d069ae6be84a2a58d'
s = ref.decode('utf-8-sig').replace('\r\n','\n')
def replace(a,b=''):
    global s
    assert s.count(a)==1, (a,s.count(a))
    s=s.replace(a,b)

replace('            held_notes<=0; pending_release<=0; release_notes<=0;\n            delivered_notes<=0; blocked_notes<=0; scan_active<=0; scan_note<=0;',
        '            scan_active<=0; scan_note<=0;')
replace('                if (event_on) delivered_notes[event_raw_note]<=1;\n                else delivered_notes[event_raw_note]<=0;')
replace('                    if (scan_offer) release_notes[scan_note]<=0;')
a=s.index('            if (key_on) begin\n');b=s.index('            // 延音期间',a);s=s[:a]+s[b:]
replace('                        release_notes<=release_notes | pending_release;\n                        pending_release<=0;')
replace('                    release_notes<=release_notes | held_notes | pending_release;\n                    held_notes<=0; pending_release<=0; sustain_down<=0;', '                    sustain_down<=0;')
a=s.index('                release_notes<=pop_event ?\n');b=s.index('                scan_active<=1; scan_note<=0;',a)
s=s[:a]+'                sustain_down<=0;\n'+s[b:]
replace("                held_notes<=0; pending_release<=0; release_notes<=0; delivered_notes<=0;\n                blocked_notes<=suppress ? (blocked_notes | held_notes) : 128'b0;")
new='''    // V047 CE/SOP candidate. Three point-written maps share write data and
    // use per-bit enables (no 128-bit feedback mux). Bulk-map priorities are
    // factored into common scalar controls, then expressed as independent SOPs.
    // All operands are OLD clock-edge values. No extra state or pipeline stage.
    wire bitmap_accepted_on=key_on && !suppress && !blocked_notes[first_data];
    wire bitmap_deferred_off=key_off && !suppress && !blocked_notes[first_data] &&
        sustain_down && (held_notes[first_data] || pending_release[first_data]);
    wire bitmap_note_write=bitmap_accepted_on || key_off;
    wire bitmap_held_clear=panic_request || entering_suppress || all_notes_off;
    wire bitmap_pending_clear=bitmap_held_clear || sustain_up;
    wire bitmap_held_data=bitmap_accepted_on && !bitmap_held_clear;
    wire bitmap_pending_data=bitmap_deferred_off && !bitmap_pending_clear;
    wire bitmap_delivered_data=event_on && !panic_request;

    // scan_offer already excludes direct notes, sustain-up, CC123 and suppress
    // entry, and already includes the synchronous mapping lookup tag check.
    wire bitmap_scan_clear=scan_offer && fifo_room;
    wire bitmap_release_keep=!panic_request && !entering_suppress;
    wire bitmap_release_pending=bitmap_release_keep && (sustain_up || all_notes_off);
    wire bitmap_release_held=bitmap_release_keep && all_notes_off;
    wire bitmap_release_delivered=!panic_request && entering_suppress;
    wire bitmap_release_pop_on=bitmap_release_delivered && pop_event && event_on;
    wire bitmap_release_pop_off=pop_event && !event_on;

    // Panic must use OLD held even when a simultaneous raw NoteOff or suppress
    // would otherwise clear it. Gate point edits off during panic explicitly.
    wire bitmap_block_keep=!panic_request || suppress;
    wire bitmap_block_import=(panic_request && suppress) || (!panic_request && entering_suppress);
    wire bitmap_block_on=key_on && suppress && !panic_request;
    wire bitmap_block_off=key_off && !panic_request;

    genvar bitmap_i;
    generate for(bitmap_i=0;bitmap_i<128;bitmap_i=bitmap_i+1) begin: bitmap_bits
        wire note_select=(first_data==bitmap_i);
        wire scan_select=(scan_note==bitmap_i);
        wire delivered_select=(event_raw_note==bitmap_i);
        wire note_write=note_select && bitmap_note_write;
        wire delivered_write=delivered_select && pop_event;
        wire release_clear=(note_select && bitmap_accepted_on) ||
                           (scan_select && bitmap_scan_clear);
        wire block_off=note_select && bitmap_block_off;
        always @(posedge clk or negedge rst_n) begin
            if(!rst_n) begin
                held_notes[bitmap_i]<=0;
                pending_release[bitmap_i]<=0;
                delivered_notes[bitmap_i]<=0;
            end else begin
                if(bitmap_held_clear || note_write)
                    held_notes[bitmap_i]<=bitmap_held_data;
                if(bitmap_pending_clear || note_write)
                    pending_release[bitmap_i]<=bitmap_pending_data;
                if(panic_request || delivered_write)
                    delivered_notes[bitmap_i]<=bitmap_delivered_data;
            end
        end
        always @(posedge clk or negedge rst_n) begin
            if(!rst_n) begin
                release_notes[bitmap_i]<=0;
                blocked_notes[bitmap_i]<=0;
            end else begin
                release_notes[bitmap_i]<=
                    (bitmap_release_keep && release_notes[bitmap_i] && !release_clear) ||
                    (bitmap_release_pending && pending_release[bitmap_i]) ||
                    (bitmap_release_held && held_notes[bitmap_i]) ||
                    (bitmap_release_delivered && delivered_notes[bitmap_i] &&
                        !(delivered_select && bitmap_release_pop_off)) ||
                    (bitmap_release_pop_on && delivered_select);
                blocked_notes[bitmap_i]<=
                    (bitmap_block_keep && blocked_notes[bitmap_i] && !block_off) ||
                    (bitmap_block_import && held_notes[bitmap_i] && !block_off) ||
                    (bitmap_block_on && note_select);
            end
        end
    end endgenerate

'''
replace('    always @(posedge clk or negedge rst_n) begin\n        if (!rst_n) begin\n            running_status',new+'    always @(posedge clk or negedge rst_n) begin\n        if (!rst_n) begin\n            running_status')
target=ROOT/'src/midi_keyboard.v'
old=target.read_bytes()
(HERE/'midi_keyboard_prior_ce_sop.v').write_bytes(old)
target.write_text(s,encoding='utf-8',newline='\n')
print('PRIOR_SHA256',hashlib.sha256(old).hexdigest())
print('CE_SOP_SHA256',hashlib.sha256(target.read_bytes()).hexdigest())
