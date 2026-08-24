import 'package:flutter/material.dart';

import 'login_screen/neo_sync_content.dart';

/// NeoSync v2 is the built-in cloud-save provider for NeoStation.
///
/// The old provider-selection carousel stored its selection only in widget
/// state, so leaving the Sync tab destroyed that state and made NeoSync look
/// disabled when the user came back. The current NeoSync experience is opened
/// directly instead; authentication and service availability are represented
/// by [NeoSyncContent] itself and persist independently of tab lifecycle.
class NeoSyncTab extends StatelessWidget {
  const NeoSyncTab({super.key});

  @override
  Widget build(BuildContext context) => const NeoSyncContent();
}
