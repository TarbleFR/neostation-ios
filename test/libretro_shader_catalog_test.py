#!/usr/bin/env python3
"""Static contract of NeoStation's shader presets (portable, no Metal needed).

Parses LibretroShaderLibrary.m and checks: menu order; translated name and
parameter labels present in LibretroLocale (English map and native keys);
licence, authors, category, upstream path and filter of every preset;
parameter ranges, unique slots below 16 and NEO_PARAM slots used by the
fragment; parameters equal to the upstream "#pragma parameter" lines kept in
each fragment; the licence header kept at the top of each fragment; the MSL
NeoUniforms members in the order of the C LibretroShaderUniforms.
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLASSES = ROOT / 'packages/libretro_internal_bridge/ios/Classes'
LIBRARY = CLASSES / 'LibretroShaderLibrary.m'
HEADER = CLASSES / 'LibretroShaderLibrary.h'
LOCALE = ROOT / 'lib/l10n/libretro_locale.dart'

ORDER = ('sharp-bilinear', 'crt-lottes-fast', 'crt-hyllian-fast', 'zfast-crt', 'scanlines-sine-abs', 'lcd3x',
         'sameboy-lcd', 'dot', 'zfast-lcd')
CATEGORIES = {'crt', 'scanlines', 'lcd', 'scaling'}
# filter_linear0 of each upstream .slangp; scanlines-sine-abs.slangp sets none.
FILTERS = {
    'sharp-bilinear': 'Linear', 'crt-lottes-fast': 'Linear', 'crt-hyllian-fast': 'Nearest', 'zfast-crt': 'Linear',
    'scanlines-sine-abs': 'FollowSmoothing', 'lcd3x': 'Nearest', 'sameboy-lcd': 'Nearest', 'dot': 'Nearest',
    'zfast-lcd': 'Linear',
}
# Upstream parameters kept at their default as constants instead of exposed.
FIXED = {'crt-lottes-fast': {'TRINITRON_CURVE'}}
# Only curvature and corner warp the picture (forced to 0 on touch screens).
DISTORTING = {('crt-lottes-fast', 'CURVATURE'), ('crt-lottes-fast', 'CORNER')}
# Words that the kept upstream licence header must contain.
LICENCE_WORDS = {
    'Public domain': 'public domain',
    'Unlicense': 'unlicense',
    'MIT': 'permission is hereby granted',
    'GPL-2.0-or-later': 'gnu general public license',
}
ENTRY = ('fragment float4 neostation_fragment(NeoVertexOut in [[stage_in]], texture2d<float> source [[texture(0)]],\n'
         '                                    sampler smp [[sampler(0)]], constant NeoUniforms &u [[buffer(0)]]) {')

STRING = r'"((?:[^"\\\n]|\\.)*)"'
CONSTANT = re.compile(r'static NSString \*const (k\w+Source) =\s*((?:@?' + STRING + r'\s*)+);')
NUMBER = r'(-?\d+(?:\.\d+)?)f'
PARAMETER = re.compile(r'MakeParameter\(@"(\w+)",\s*@"(\w+)",\s*' + r',\s*'.join([NUMBER] * 4) +
                       r',\s*(\d+),\s*(YES|NO)\)')
PRESET = re.compile(r'MakePreset\(' + r',\s*'.join(['@' + STRING] * 6) +
                    r',\s*LibretroShaderFilter(\w+),\s*@\[(.*?)\],\s*(k\w+Source)\)', re.S)
PRAGMA = re.compile(r'^// #pragma parameter (\w+) "[^"]*" ' + ' '.join([r'(-?[\d.]+)'] * 4) + r'\s*$', re.M)
MSL_TYPES = {'simd_float4': 'float4', 'simd_float2': 'float2', 'uint32_t': 'uint', 'float': 'float'}

errors = []


def require(condition, message):
    if not condition:
        errors.append(message)


def unescape(text):
    return re.sub(r'\\(.)', lambda match: {'n': '\n', 't': '\t'}.get(match.group(1), match.group(1)), text)


def string_constants(source):
    constants = {}
    for match in CONSTANT.finditer(source):
        constants[match.group(1)] = unescape(''.join(re.findall(STRING, match.group(2))))
    return constants


def english_and_native_keys(dart):
    start = dart.index("'en': {")
    following = re.search(r"\n\s*'(?:fr|de|es|it|pt|ru|id|ja|ko|zh|zh_Hant)': \{", dart[start:])
    english = dart[start:start + following.start()] if following else dart[start:]
    native_start = dart.index('nativeKeys = <String>[')
    native = dart[native_start:dart.index('];', native_start)]
    return set(re.findall(r"^\s*'(\w+)'\s*:", english, re.M)), set(re.findall(r"'(\w+)'", native))


def struct_members(text, pattern):
    return [(MSL_TYPES.get(kind, kind), name + (size or ''))
            for kind, name, size in re.findall(pattern, text, re.M)]


def main():
    source = LIBRARY.read_text(encoding='utf-8')
    header = HEADER.read_text(encoding='utf-8')
    english, native = english_and_native_keys(LOCALE.read_text(encoding='utf-8'))
    constants = string_constants(source)

    prelude = constants.get('kPreludeSource', '')
    passthrough = constants.get('kPassthroughSource', '')
    require('vertex NeoVertexOut neostation_vertex(uint vid [[vertex_id]], constant float4 *quad [[buffer(0)]])'
            in prelude, 'prelude defines neostation_vertex reading the quad from buffer 0')
    for helper in ('inline float4 NEO_SAMPLE(texture2d<float> source, sampler smp, constant NeoUniforms &u, '
                   'float2 coord)', 'inline float NEO_PARAM(constant NeoUniforms &u, uint slot)'):
        require(helper in prelude, f'prelude defines {helper}')
    require(passthrough.count(ENTRY) == 1, 'pass-through defines neostation_fragment once')

    c_struct = header[header.index('typedef struct {'):header.index('} LibretroShaderUniforms;')]
    msl_struct = prelude[prelude.index('struct NeoUniforms {'):]
    msl_struct = msl_struct[:msl_struct.index('};')]
    c_members = struct_members(c_struct, r'^\s*(simd_float4|simd_float2|uint32_t|float)\s+(\w+)(\[\d+\])?;')
    msl_members = struct_members(msl_struct, r'^\s*(float4|float2|uint|float)\s+(\w+)(\[\d+\])?;')
    require(c_members and c_members == msl_members,
            f'NeoUniforms {msl_members} must mirror LibretroShaderUniforms {c_members}')
    require(re.search(r'const NSUInteger LibretroShaderLanguageVersion = \(2 << 16\) \+ 4;', source) is not None,
            'LibretroShaderLanguageVersion is MTLLanguageVersion2_4')

    presets = PRESET.findall(source)
    identifiers = tuple(preset[0] for preset in presets)
    require(identifiers == ORDER, f'presets in menu order: {identifiers}')
    for identifier, name_key, category, upstream, licence, authors, filter_name, body, constant in presets:
        fragment = constants.get(constant, '')
        require(fragment, f'{identifier}: fragment {constant} found')
        require(name_key in english, f'{identifier}: name {name_key} missing from the English LibretroLocale map')
        require(name_key in native, f'{identifier}: name {name_key} missing from LibretroLocale.nativeKeys')
        require(category in CATEGORIES, f'{identifier}: category {category}')
        require(re.fullmatch(r'[\w-]+(?:/[\w-]+)*\.slang', upstream) is not None,
                f'{identifier}: upstream path {upstream}')
        require(licence in LICENCE_WORDS and authors.strip(), f'{identifier}: licence {licence!r} and authors')
        require(FILTERS.get(identifier) == filter_name, f'{identifier}: filter {filter_name}')
        require(fragment.lstrip().startswith(('/*', '//')), f'{identifier}: licence header first')
        words = LICENCE_WORDS.get(licence)
        if words:
            require(words in fragment[:fragment.find(ENTRY)].lower(),
                    f'{identifier}: upstream {licence} header kept')
        require(fragment.count(ENTRY) == 1, f'{identifier}: defines neostation_fragment once, contract signature')

        parameters = PARAMETER.findall(body)
        require(parameters, f'{identifier}: parameters parsed')
        pragmas = {match[0]: tuple(float(value) for value in match[1:]) for match in PRAGMA.findall(fragment)}
        slots = set()
        for name, label, *numbers, slot, distorts in parameters:
            default, minimum, maximum, step = (float(number) for number in numbers)
            slot = int(slot)
            require(label in english, f'{identifier}.{name}: label {label} missing from the English LibretroLocale map')
            require(label in native, f'{identifier}.{name}: label {label} missing from LibretroLocale.nativeKeys')
            require(minimum <= default <= maximum and step > 0, f'{identifier}.{name}: default inside [min, max]')
            require(slot < 16 and slot not in slots, f'{identifier}.{name}: slot {slot} unique and below 16')
            slots.add(slot)
            require(name in pragmas, f'{identifier}.{name}: upstream #pragma parameter line kept')
            if name in pragmas:
                require(all(abs(a - b) < 1e-6 for a, b in zip((default, minimum, maximum, step), pragmas[name])),
                        f'{identifier}.{name}: {default} {minimum} {maximum} {step} equals upstream {pragmas[name]}')
            require((distorts == 'YES') == ((identifier, name) in DISTORTING),
                    f'{identifier}.{name}: distortsGeometry {distorts}')
        exposed = {parameter[0] for parameter in parameters}
        require(set(pragmas) - exposed == FIXED.get(identifier, set()),
                f'{identifier}: upstream parameters neither exposed nor fixed: {set(pragmas) - exposed}')
        for name in FIXED.get(identifier, set()) & set(pragmas):
            constant_value = re.search(rf'\bfloat {name} = (-?[\d.]+);', fragment)
            require(constant_value is not None and float(constant_value.group(1)) == pragmas[name][0],
                    f'{identifier}.{name}: fixed at its upstream default {pragmas[name][0]}')
        used = {int(slot) for slot in re.findall(r'NEO_PARAM\(u, (\d+)\)', fragment)}
        require(used == slots, f'{identifier}: NEO_PARAM slots {sorted(used)} match the parameters {sorted(slots)}')

    require('@"LIBRETRO_' not in source, 'no launch error code in the shader library')
    require('NSLocalizedString' not in source and 'preferredLanguages' not in source, 'no native translation')
    require('#import <Metal/' not in source and '@import' not in source, 'portable: Foundation and simd only')

    if errors:
        raise SystemExit('libretro shader catalog:\n  ' + '\n  '.join(errors))
    print(f'libretro shader catalog: OK ({len(presets)} presets)')


if __name__ == '__main__':
    main()
