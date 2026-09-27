#!/usr/bin/env python3
"""Reject malformed conditional directives in modified RPCS3 Core sources."""
import json
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DIRECTIVE = re.compile(r'^\s*#\s*(if|ifdef|ifndef|elif|else|endif)\b')
INLINE = re.compile(r'\S\s*#\s*(?:if|ifdef|ifndef|elif|else|endif)\b')


def check_directives(path: str, source: str) -> None:
    stack = []
    for number, line in enumerate(source.splitlines(), 1):
        if not line.lstrip().startswith('#') and INLINE.search(line):
            raise ValueError(f'{path}:{number}: conditional directive is not on its own line')
        match = DIRECTIVE.match(line)
        if not match:
            continue
        kind = match.group(1)
        if kind in ('if', 'ifdef', 'ifndef'):
            stack.append((number, False))
        elif kind == 'endif':
            if not stack:
                raise ValueError(f'{path}:{number}: unmatched #endif')
            stack.pop()
        elif not stack:
            raise ValueError(f'{path}:{number}: unmatched #{kind}')
        elif kind == 'else':
            if stack[-1][1]:
                raise ValueError(f'{path}:{number}: repeated #else')
            stack[-1] = (stack[-1][0], True)
        elif stack[-1][1]:
            raise ValueError(f'{path}:{number}: #elif after #else')
    if stack:
        raise ValueError(f'{path}:{stack[-1][0]}: unterminated conditional')


class BalanceTests(unittest.TestCase):
    def test_rejects_inline_and_unterminated_directives(self):
        for source in ('#if ARM\nx();#else\n#endif\n', '#if ARM\nx();\n',
                       '#if ARM\n#else\n#elif IOS\n#endif\n'):
            with self.assertRaises(ValueError):
                check_directives('fixture.cpp', source)

    def test_accepts_nested_directives(self):
        check_directives('fixture.cpp', '#ifdef ARM\n#if IOS\n#else\n#endif\n#endif\n')


if __name__ == '__main__':
    if len(sys.argv) == 1:
        unittest.main()
    elif len(sys.argv) == 2:
        source = Path(sys.argv[1])
        manifest = json.loads((ROOT / 'build-utils/rpcs3/canonical-source.json').read_text())
        checked = 0
        for relative in manifest['files_sha256']:
            if Path(relative).suffix in ('.cpp', '.h', '.hpp'):
                check_directives(relative, (source / relative).read_text())
                checked += 1
        print(f'PASS: conditional directives in {checked} materialized Core files')
    else:
        raise SystemExit('usage: rpcs3_preprocessor_balance_test.py [rpcs3-source-root]')
