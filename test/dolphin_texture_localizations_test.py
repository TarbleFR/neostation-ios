"""Validate every native texture import message and its generated catalog."""
from pathlib import Path
import json
import re

ROOT = Path(__file__).resolve().parents[1]
rows = json.loads((ROOT / 'native/dolphin_textures/labels.json').read_text())
locales = {'en', 'es', 'ru', 'zh', 'zh_Hant', 'pt', 'fr', 'de', 'it', 'id', 'ja', 'ko'}
assert set(rows) == locales
keys = set(rows['en'])
for locale, values in rows.items():
    assert set(values) == keys, locale
    for key, value in values.items():
        assert isinstance(value, str) and value.strip(), (locale, key)
        assert set(re.findall(r'\{\w+\}', value)) == set(re.findall(r'\{\w+\}', rows['en'][key])), (locale, key)

objc = lambda value: '@' + json.dumps(value, ensure_ascii=False)
expected = '\n'.join(objc(locale) + ': @{' + ','.join(objc(key) + ': ' + objc(value) for key, value in values.items()) + '},' for locale, values in rows.items())
header = (ROOT / 'packages/dolphin_internal_bridge/ios/Classes/DOLTextureLabels.h').read_text()
assert header.split('values=@{\n', 1)[1].split('\n };});', 1)[0] == expected, 'regenerate the native texture catalog'
assert rows['zh_Hant']['regionMessage'] != rows['zh']['regionMessage']
print('PASS HD texture locales: all 12 catalogs, matching placeholders, canonical native generation')
