from pathlib import Path

p = Path('lib/services/armsx2_library_service.dart')
text = p.read_text(encoding='utf-8')

# Physical games discovered recursively from the linked ARMSX2 root.
physical_old = """    final uri = Uri(\n      scheme: 'armsx2',\n      host: 'launch',\n      queryParameters: {'game': fileName},\n    );\n"""
physical_new = """    // ARMSX2 treats '+' literally in its `game` query value. Dart's\n    // Uri(queryParameters: ...) uses form-style encoding where spaces become\n    // '+'. Percent-encode the filename so spaces are `%20` and a real plus\n    // character becomes `%2B`.\n    final encodedFileName = Uri.encodeComponent(fileName);\n    final uri = Uri.parse('armsx2://launch?game=$encodedFileName');\n"""
if physical_old not in text:
    raise SystemExit('ARMSX2 physical launch URI anchor not found')
text = text.replace(physical_old, physical_new, 1)

# Legacy/exported virtual rows may still exist on upgraded installations. Make
# their generated fallback URL use the exact same encoding rule, so an old cache
# can never reintroduce `Dragon+Ball+...` launch names.
virtual_old = """            : Uri(\n                scheme: _virtualScheme,\n                host: 'launch',\n                queryParameters: {'game': fileName},\n              );\n"""
virtual_new = """            : Uri.parse(\n                'armsx2://launch?game=${Uri.encodeComponent(fileName)}',\n              );\n"""
if virtual_old not in text:
    raise SystemExit('ARMSX2 virtual launch URI anchor not found')
text = text.replace(virtual_old, virtual_new, 1)

# The Build 171 cache-based physical launch fallback contains another Uri()
# constructor with the same form-style game query. Keep that constructor but
# feed it an already percent-encoded raw query instead of queryParameters.
remaining_form_query = "queryParameters: {'game': fileName},"
if remaining_form_query in text:
    text = text.replace(
        remaining_form_query,
        "query: 'game=${Uri.encodeComponent(fileName)}',",
    )

if remaining_form_query in text:
    raise SystemExit('An ARMSX2 form-style game query builder still remains')

p.write_text(text, encoding='utf-8')
print('Build 179: every ARMSX2 game launch path uses percent encoding')
