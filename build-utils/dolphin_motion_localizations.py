#!/usr/bin/env python3
"""Stage only the motion privacy string, preserving existing localized keys."""
from pathlib import Path
import json
import re

ROOT=Path(__file__).resolve().parents[1]
STRINGS=json.loads((ROOT/'native/dolphin_motion/strings.json').read_text(encoding='utf-8'))

def stage(runner: Path) -> None:
    for language,strings in STRINGS.items():
        language={'zh':'zh-Hans','zh_Hant':'zh-Hant'}.get(language,language)
        target=runner/(language+'.lproj')/'InfoPlist.strings'
        target.parent.mkdir(parents=True,exist_ok=True)
        text=target.read_text(encoding='utf-8') if target.exists() else ''
        entry='"NSMotionUsageDescription" = '+json.dumps(strings['usage'],ensure_ascii=False)+';'
        pattern=r'(?m)^[ \t]*"?NSMotionUsageDescription"?\s*=\s*"(?:\\.|[^"\\])*"\s*;'
        if re.search(pattern,text):
            text=re.sub(pattern,lambda _:entry,text)
        else:
            text=text.rstrip()+'\n'+entry+'\n'
        target.write_text(text,encoding='utf-8')
