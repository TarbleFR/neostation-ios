"""Regenerate canonical native cheat/texture labels and NeoSwap Dart labels."""
from pathlib import Path
import json
ROOT=Path(__file__).resolve().parents[1]
def objc(value): return '@'+json.dumps(value,ensure_ascii=False)
def dictionary(rows):
    return '\n'.join(objc(lang)+': @{'+','.join(objc(k)+': '+objc(v) for k,v in values.items())+'},' for lang,values in rows.items())
cheats=json.loads((ROOT/'native/cheats/bulk-labels.json').read_text())
header=ROOT/'native/cheats/NeoCheatLabels.h';source=header.read_text()
begin=source.index('batch=@{')+len('batch=@{');end=source.index('\n};});',begin)
source=source[:begin]+'\n'+dictionary(cheats)+source[end:];header.write_text(source)
for package,editor in [('dolphin_internal_bridge','DOLManualCheatEditor'),('armsx2_internal_bridge','ARMSX2ManualCheatEditor')]:
    classes=ROOT/'packages'/package/'ios/Classes'
    (classes/'NeoCheatLabels.h').write_text(source)
    (classes/(editor+'.h')).write_text((ROOT/'native/cheats/NeoManualCheatEditor.template.h').read_text().replace('NEO_EDITOR_CLASS',editor))
textures=json.loads((ROOT/'native/dolphin_textures/labels.json').read_text())
texture_header='''// SPDX-License-Identifier: GPL-3.0-or-later
// Generated from native/dolphin_textures/labels.json.
#pragma once
#import <Foundation/Foundation.h>
static NSString* DOLTextureText(NSString* key,NSString* locale) {
 static NSDictionary* values;static dispatch_once_t once;dispatch_once(&once,^{values=@{
'''+dictionary(textures)+'''
 };});
 NSString* language=[locale stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
 if([language hasPrefix:@"zh_Hant"] || [language hasPrefix:@"zh_TW"] || [language hasPrefix:@"zh_HK"])language=@"zh_Hant";
 else language=[language componentsSeparatedByString:@"_"].firstObject;
 return values[language][key]?:values[@"en"][key]?:key;
}
'''
(ROOT/'packages/dolphin_internal_bridge/ios/Classes/DOLTextureLabels.h').write_text(texture_header)
path=ROOT/'lib/l10n/neoswap_locale.dart';source=path.read_text();start=source.index('  static const Map<String, Map<String, String>> values = ')
rows=json.loads((ROOT/'native/neoswap/localizations.json').read_text())
literal=json.dumps(rows,ensure_ascii=False,indent=2).replace('$','\\$')
path.write_text(source[:start]+'  static const Map<String, Map<String, String>> values = '+literal+';\n}\n')
print('PASS generated canonical labels and both editors')
