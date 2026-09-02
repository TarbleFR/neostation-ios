from pathlib import Path

p = Path('lib/services/armsx2_library_service.dart')
text = p.read_text(encoding='utf-8')
old = """    final uri = Uri(\n      scheme: 'armsx2',\n      host: 'launch',\n      queryParameters: {'game': fileName},\n    );\n"""
new = """    // ARMSX2 treats '+' literally in its `game` query value. Dart's\n    // Uri(queryParameters: ...) uses form-style encoding where spaces become\n    // '+', which makes names such as `Dragon Ball Z - Budokai 2.iso` fail\n    // lookup inside ARMSX2. Encode the filename as a URI component so spaces\n    // are `%20` (and a real '+' in a filename becomes `%2B`).\n    final encodedFileName = Uri.encodeComponent(fileName);\n    final uri = Uri.parse('armsx2://launch?game=$encodedFileName');\n"""
if old not in text:
    raise SystemExit('ARMSX2 physical launch URI anchor not found')
p.write_text(text.replace(old, new, 1), encoding='utf-8')
print('Build 179: ARMSX2 physical launch filenames use percent encoding')
