import 'package:flutter/material.dart';

/// Presentation only. Never queries an external installation or initializes JIT.
/// The strict identities match the existing native GameCube/Wii launch route.
class DolphinSystemEmulatorCard extends StatelessWidget {
  const DolphinSystemEmulatorCard({super.key});

  static bool appliesTo({required String systemFolderName, required bool isIOS}) {
    final system = systemFolderName.trim().toLowerCase();
    return isIOS && (system == 'gc' || system == 'wii');
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: const [
        ListTile(
          key: ValueKey('dolphin-system-emulator'),
          leading: Icon(Icons.videogame_asset_outlined),
          title: Text('Dolphin iOS'),
          subtitle: Text('NeoStation'),
        ),
      ],
    );
  }
}
