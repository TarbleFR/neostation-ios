#!/usr/bin/env python3
from pathlib import Path

path = Path('lib/screens/settings_screen/new_settings_options/directories_settings_content.dart')
text = path.read_text()
replacements = {
    "  List<Widget> _iosEmulatorCards(ThemeData theme) {  List<Widget> _iosEmulatorCards(ThemeData theme) {":
        "  List<Widget> _iosEmulatorCards(ThemeData theme) {",
    "  List<Widget> _iosEmulatorCards(ThemeData theme) {\n  List<Widget> _iosEmulatorCards(ThemeData theme) {":
        "  List<Widget> _iosEmulatorCards(ThemeData theme) {",
    "  Widget _buildIOSArmsx2Section(ThemeData theme) {  Widget _buildIOSArmsx2Section(ThemeData theme) {":
        "  Widget _buildIOSArmsx2Section(ThemeData theme) {",
    "  Widget _buildIOSArmsx2Section(ThemeData theme) {\n  Widget _buildIOSArmsx2Section(ThemeData theme) {":
        "  Widget _buildIOSArmsx2Section(ThemeData theme) {",
}
changed = False
for old, new in replacements.items():
    if old in text:
        text = text.replace(old, new, 1)
        changed = True
if not changed:
    raise SystemExit('Expected duplicated RPCS3 settings patch markers were not found')
path.write_text(text)
