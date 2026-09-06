import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import '../../providers/icloud_save_provider.dart';
import '../../sync/i_sync_provider.dart';
import '../../themes/corner_radii.dart';
import '../../utils/gamepad_nav.dart';
import '../../services/gamepad/gamepad_navigation_manager.dart';
import '../../widgets/confirm_action_dialog.dart';
import '../app_screen.dart';

/// Same cloud-tab layout: status/settings on the left, cloud saves on the right.
/// No separate login, payment plan or private server is involved.
class CloudSavesTab extends StatefulWidget {
  const CloudSavesTab({super.key});
  @override State<CloudSavesTab> createState() => _CloudSavesTabState();
}

class _CloudSavesTabState extends State<CloudSavesTab> {
  late final GamepadNavigation _navigation;
  final ScrollController _scroll = ScrollController();
  Timer? _refreshTimer;
  String? _selected;
  bool _dialog = false, _refreshing = false;
  String? _message;
  bool get _fr => (FlutterLocalization.instance.currentLocale?.languageCode ?? Localizations.localeOf(context).languageCode) == 'fr';
  String _text(String fr, String en) => _fr ? fr : en;
  ICloudSaveProvider get cloud => context.read<ICloudSaveProvider>();
  @override void initState() {
    super.initState();
    _navigation = GamepadNavigation(
      onNavigateUp: (_) => _move(-1), onNavigateDown: (_) => _move(1),
      onSelectItem: () { if (_selected != null) _restore(_selected!); else _enable(); },
      onXButton: () { if (_selected != null) _remove(_selected!); },
      onFavorite: () => _run(() => cloud.fullSync()),
      onPreviousTab: () { if (!_dialog) AppNavigation.previousTab(); },
      onNextTab: () { if (!_dialog) AppNavigation.nextTab(); },
      onBack: () { if (!_dialog) AppNavigation.goToTab(AppTabs.systems); });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _navigation.initialize();
      GamepadNavigationManager.pushLayer('icloud_saves', onActivate: () => _navigation.activate(), onDeactivate: () => _navigation.deactivate());
      _refresh();
      // Poll only while this visible tab exists. iOS, not this timer, uploads.
      _refreshTimer = Timer.periodic(const Duration(seconds: 8), (_) => _refresh());
    });
  }
  Future<void> _refresh() async {
    if (!mounted || _dialog || cloud.busy || _refreshing || !cloud.isAuthenticated) return;
    _refreshing = true;
    try { await cloud.refresh(); }
    catch (error) { if (mounted) setState(() => _message = error.toString()); }
    finally { _refreshing = false; }
  }
  void _move(int direction) {
    if (_dialog) return;
    final rows = cloud.revisions;
    if (rows.isEmpty) return;
    final previous = rows.indexWhere((e) => e.id == _selected);
    final index = (previous + direction).clamp(0, rows.length - 1).toInt();
    setState(() => _selected = rows[index].id);
    if (_scroll.hasClients) _scroll.animateTo((index * 88.r).clamp(0, _scroll.position.maxScrollExtent).toDouble(),
      duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
  }
  Future<void> _run(Future<SyncResult> Function() action) async {
    try {
      final result = await action();
      if (mounted) setState(() => _message = result.message);
    } catch (error) { if (mounted) setState(() => _message = error.toString()); }
  }
  Future<bool> _confirm(String title, String body, String button, IconData icon) async {
    if (_dialog || cloud.busy) return false;
    _dialog = true;
    try { return await ConfirmActionDialog.show(context, title: title, body: body, confirmLabel: button, icon: icon); }
    finally { _dialog = false; }
  }
  Future<void> _enable() async {
    if (!await _confirm('iCloud Saves', _text(
      'NeoStation va copier les sauvegardes des émulateurs liés dans votre iCloud Drive. Choisissez un dossier dans iCloud Drive : NeoStation/Saves sera créé après votre accord. Les fichiers resteront aussi dans leur emplacement local. Aucun ancien fichier cloud ne sera importé ou supprimé. Un compte Apple connecté et iCloud Drive activé sont nécessaires.',
      'NeoStation will copy saves from linked emulators to your iCloud Drive. Select an iCloud Drive folder: NeoStation/Saves will be created with your permission. Native local saves are kept. Previous cloud files are not imported or deleted. A signed-in Apple Account and enabled iCloud Drive are required.'),
      _text('Autoriser le dossier', 'Authorize folder'), Icons.cloud_outlined)) return;
    _dialog = true; _navigation.deactivate();
    try { await _run(() => cloud.login()); }
    finally { _dialog = false; if (mounted) _navigation.activate(); }
    if (mounted && cloud.isAuthenticated) await _run(() => cloud.fullSync());
  }
  Future<void> _restore(String id) async {
    final matches = cloud.revisions.where((r) => r.id == id).toList();
    if (matches.isEmpty) return;
    final r = matches.single;
    if (!await _confirm(_text('Restaurer la sauvegarde', 'Restore save'),
      '${r.title}\n${r.emulator} · ${r.system}\n${r.modified.toLocal()}\n\n${_text("Fermez le jeu. Cette version remplacera la sauvegarde locale correspondante ; une copie de sécurité locale sera conservée. Les cartes mémoire partagées peuvent contenir plusieurs jeux.", "Close the game. This revision will replace the matching native save; the previous local copy is preserved. Shared memory cards may contain several games.")}',
      _text('Restaurer', 'Restore'), Icons.restore)) return;
    await _run(() => cloud.restoreRevision(id));
  }
  Future<void> _remove(String id) async {
    if (!await _confirm(_text('Retirer cette version du cloud ?', 'Remove this cloud revision?'),
      _text('Cette version sera déplacée dans la corbeille du dossier cloud. Les copies de contenu identique ne seront pas renvoyées automatiquement. Les sauvegardes locales restent intactes.',
        'This revision moves to the cloud folder trash. Identical content will not be uploaded again automatically. Native local saves are not deleted.'),
      _text('Retirer', 'Remove'), Icons.delete_outline)) return;
    await _run(() => cloud.deleteRemote(id));
  }
  Future<void> _linkFolder() async {
    if (_dialog || cloud.busy) return;
    _dialog = true; _navigation.deactivate();
    final emulator = TextEditingController(), system = TextEditingController();
    try {
      final accepted = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
        title: Text(_text('Lier un émulateur', 'Link emulator')),
        content: SizedBox(width: 360, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_text('Pour un autre émulateur, choisissez uniquement son dossier de sauvegardes, jamais ses jeux, BIOS ou l’ensemble de ses données. Ce dossier sera sauvegardé comme une unité partagée.',
            'For another emulator, select only its save folder, never ROMs, BIOS files or the whole app data directory. This folder is backed up as one shared unit.')),
          TextField(controller: emulator, maxLength: 100, decoration: InputDecoration(labelText: _text('Émulateur', 'Emulator'))),
          TextField(controller: system, maxLength: 100, decoration: InputDecoration(labelText: _text('Console', 'Console'))),
        ]))), actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(_text('Annuler', 'Cancel'))),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(_text('Choisir le dossier Saves', 'Select Saves folder'))),
        ]));
      if (accepted == true) {
        await cloud.sources.addFolder(emulator.text, system.text);
        await _run(() => cloud.fullSync());
      }
    } catch (error) { if (mounted) setState(() => _message = error.toString()); }
    finally {
      emulator.dispose(); system.dispose(); _dialog = false;
      if (mounted) _navigation.activate();
    }
  }
  @override void dispose() {
    _refreshTimer?.cancel(); GamepadNavigationManager.popLayer('icloud_saves');
    _navigation.dispose(); _scroll.dispose(); super.dispose();
  }
  Widget _panel(Widget child) {
    final theme = Theme.of(context);
    return Container(padding: EdgeInsets.all(20.r), decoration: BoxDecoration(
      color: theme.colorScheme.surface,
      borderRadius: CornerRadii.of(context).radiusExternal,
      border: Border.all(color: theme.colorScheme.primary.withValues(alpha: .25))), child: child);
  }
  @override Widget build(BuildContext context) {
    final provider = context.watch<ICloudSaveProvider>();
    final theme = Theme.of(context), rows = provider.revisions;
    final message = provider.lastError ?? _message;
    final left = _panel(SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('iCloud Saves', style: theme.textTheme.headlineSmall), SizedBox(height: 18.r),
      Row(children: [Icon(provider.isAuthenticated ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
        color: provider.isAuthenticated ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant), SizedBox(width: 12.r),
        Expanded(child: Text(provider.isAuthenticated ? _text('Dossier iCloud Drive connecté', 'iCloud Drive folder connected') :
          _text('Compte Apple et iCloud Drive requis', 'Apple Account and iCloud Drive required')))]),
      SizedBox(height: 12.r), Text('iCloud Drive / NeoStation / Saves', style: theme.textTheme.bodySmall),
      SizedBox(height: 18.r),
      if (provider.connected) SwitchListTile(contentPadding: EdgeInsets.zero,
        title: Text(_text('Sauvegardes automatiques', 'Automatic backups')),
        subtitle: Text(_text('Au démarrage et au retour d’un jeu', 'At startup and when returning from a game')),
        value: provider.enabled, onChanged: provider.busy && !provider.enabled ? null : (v) async {
          try { await provider.setEnabled(v); } catch (e) { if (mounted) setState(() => _message = e.toString()); }
        })
      else FilledButton.icon(onPressed: provider.busy ? null : _enable, icon: const Icon(Icons.cloud_outlined),
        label: Text(_text('Activer iCloud Saves', 'Enable iCloud Saves'))),
      SizedBox(height: 16.r),
      Text('${rows.length} ${_text("versions", "revisions")} · ${(provider.usedBytes / (1024 * 1024)).toStringAsFixed(1)} MB'),
      Text(_text('Espace utilisé par NeoStation, pas le quota total iCloud.', 'Space used by NeoStation, not the total iCloud quota.'), style: theme.textTheme.bodySmall),
      SizedBox(height: 16.r),
      FilledButton.icon(onPressed: provider.busy || !provider.isAuthenticated ? null : () => _run(() => provider.fullSync()),
        icon: const Icon(Icons.backup_outlined), label: Text(_text('Sauvegarder maintenant · Y', 'Back up now · Y'))),
      TextButton.icon(onPressed: provider.busy ? null : _linkFolder, icon: const Icon(Icons.create_new_folder_outlined),
        label: Text(_text('Lier un autre émulateur', 'Link another emulator'))),
      if (provider.connected) TextButton(onPressed: provider.busy ? null : () async {
        if (await _confirm(_text('Déconnecter iCloud Saves ?', 'Disconnect iCloud Saves?'),
          _text('La synchronisation s’arrête. Tous les fichiers sont conservés.', 'Synchronization stops. All files are kept.'),
          _text('Déconnecter', 'Disconnect'), Icons.link_off)) await provider.logout();
      }, child: Text(_text('Déconnecter le dossier', 'Disconnect folder'))),
      if (provider.busy) const LinearProgressIndicator(),
      if (message != null) Padding(padding: EdgeInsets.only(top: 12.r), child: SelectableText(message, style: theme.textTheme.bodySmall)),
      for (final warning in provider.sourceWarnings.entries) Padding(padding: EdgeInsets.only(top: 8.r), child:
        SelectableText('${warning.key}: ${warning.value}', style: theme.textTheme.bodySmall)),
    ])));
    final right = _panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [Icon(Icons.cloud, color: theme.colorScheme.primary), SizedBox(width: 12.r),
        Expanded(child: Text(_text('Sauvegardes dans iCloud', 'Saves in iCloud'), style: theme.textTheme.titleLarge)),
        IconButton(tooltip: _text('Actualiser', 'Refresh'), onPressed: provider.busy ? null : _refresh, icon: const Icon(Icons.refresh))]),
      Padding(padding: EdgeInsets.symmetric(vertical: 10.r), child: Text(_text(
        '${provider.pendingCount} transfert(s) en attente · ${provider.invalidCount} fichier(s) à vérifier',
        '${provider.pendingCount} pending transfers · ${provider.invalidCount} files to review'), style: theme.textTheme.bodySmall)),
      Expanded(child: rows.isEmpty ? Center(child: Text(_text('Aucune version disponible. Les sauvegardes locales restent intactes.',
        'No revisions available. Native local saves remain unchanged.'))) : ListView.builder(
        controller: _scroll, itemCount: rows.length, itemBuilder: (context, index) {
          final r = rows[index]; final selected = r.id == _selected;
          final fg = selected ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface;
          return Container(margin: EdgeInsets.only(bottom: 8.r), decoration: BoxDecoration(
            color: selected ? theme.colorScheme.primary : theme.colorScheme.surfaceContainerLow,
            borderRadius: CornerRadii.of(context).radiusInternal),
            child: ListTile(onTap: () => setState(() => _selected = r.id), textColor: fg, iconColor: fg,
              leading: const Icon(Icons.save_outlined),
              title: Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${r.emulator} · ${r.system} · ${r.kind}\n${(r.size / 1024).toStringAsFixed(1)} KB · ${r.modified.toLocal().toString().split(".").first}\n${r.transferState == "uploaded" ? _text("Transfert iCloud confirmé", "iCloud upload confirmed") : r.transferState == "error" ? _text("Erreur de transfert iCloud", "iCloud transfer error") : _text("Copie déposée · transfert en attente", "Copy staged · upload pending")}',
                style: TextStyle(color: fg.withValues(alpha: .8), fontSize: 10.r)),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(tooltip: _text('Restaurer', 'Restore'), onPressed: provider.busy ? null : () => _restore(r.id), icon: const Icon(Icons.download_outlined)),
                IconButton(tooltip: _text('Retirer du cloud', 'Remove from cloud'), onPressed: provider.busy ? null : () => _remove(r.id), icon: const Icon(Icons.delete_outline)),
              ])));
        })),
    ]));
    return Padding(padding: EdgeInsets.all(20.r), child: LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxWidth >= 680) return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(flex: 4, child: left), SizedBox(width: 18.r), Expanded(flex: 6, child: right)]);
      return Column(children: [SizedBox(height: constraints.maxHeight * .45, child: left), SizedBox(height: 12.r), Expanded(child: right)]);
    }));
  }
}
