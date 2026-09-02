from pathlib import Path

p = Path('lib/screens/settings_screen/new_settings_options/directories_settings_content.dart')
text = p.read_text(encoding='utf-8')

retro_start = text.find('  Widget _buildIOSRetroArchSection')
retro_end = text.find('  Widget _buildIOSRpcs3Section', retro_start)
if retro_start < 0 or retro_end < 0:
    raise SystemExit('RetroArch settings section not found')
retro = text[retro_start:retro_end].replace('hasLibrary', 'hasSynced')
text = text[:retro_start] + retro + text[retro_end:]

arms_start = text.find('  Widget _buildIOSArmsx2Section')
arms_end = text.find('  Widget _buildIOSMeloNXSection', arms_start)
if arms_start < 0 or arms_end < 0:
    raise SystemExit('ARMSX2 settings section not found')
arms = text[arms_start:arms_end].replace('hasSynced', 'hasLibrary')
text = text[:arms_start] + arms + text[arms_end:]

p.write_text(text, encoding='utf-8')
print('Scoped ARMSX2 status variable fix applied')
