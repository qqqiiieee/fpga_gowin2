"""Host-only: remove the web literal (larger than MSVC's literal size limit).

All sketch functions, including the actual JSON serializer/HTTP apply handler,
are preserved verbatim. The actual web literal is tested separately in Edge.
"""
from pathlib import Path
ROOT = Path(__file__).resolve().parent
source = (ROOT/'../../esp32_phone/esp32_phone.ino').read_text(encoding='utf-8')
assert source.count('#include "web_ui.h"') == 1
source = source.replace('#include "web_ui.h"', 'static const char PHONE_HTML[] = "";')
(ROOT/'build/api_sketch.inc').write_text(source, encoding='utf-8')
