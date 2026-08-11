import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/llm/llm_provider.dart';
import '../services/cover_service.dart';
import '../services/llm/ollama_manager.dart';
import '../services/llm/summary_cache.dart';
import '../services/ocr_service.dart';
import '../services/settings_service.dart';
import '../services/theme_controller.dart';
import '../services/system_info.dart';
import 'model_manager_sheet.dart';

class SettingsScreen extends StatefulWidget {
  final SettingsService settings;
  final ThemeController theme;
  const SettingsScreen({
    super.key,
    required this.settings,
    required this.theme,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final Map<String, bool> _hasKey = {};

  @override
  void initState() {
    super.initState();
    _refreshKeys();
  }

  Future<void> _refreshKeys() async {
    for (final p in kProviders) {
      _hasKey[p.id] = await widget.settings.hasKey(p.keyName);
    }
    if (mounted) setState(() {});
  }

  Future<void> _editKey(LlmProvider provider) async {
    final controller = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${provider.name} API key'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Stored in this device\'s secure store (Keychain / Keystore / '
              'libsecret) — never in a file and never in the repo.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              obscureText: true,
              decoration: InputDecoration(
                labelText: provider.keyName,
                border: const OutlineInputBorder(),
                helperText: provider.keyUrl,
                helperMaxLines: 2,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          if (_hasKey[provider.id] == true)
            TextButton(
              onPressed: () async {
                await widget.settings.setKey(provider.keyName!, '');
                if (context.mounted) Navigator.pop(context, true);
              },
              child: const Text('Remove'),
            ),
          FilledButton(
            onPressed: () async {
              await widget.settings.setKey(provider.keyName!, controller.text);
              if (context.mounted) Navigator.pop(context, true);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved == true) await _refreshKeys();
  }

  Future<void> _editModel(LlmProvider provider) async {
    final current =
        widget.settings.modelFor(provider.id) ?? provider.defaultModel;

    // For Ollama the installed list is the truth; the hard-coded suggestions
    // are only a starting point and may not be pulled.
    final installed = provider is OllamaProvider
        ? await OllamaProvider.installedModels()
        : const <String>[];
    final options = <String>{
      ...installed,
      ...provider.suggestedModels,
      current,
    }.toList();

    if (!mounted) return;
    final controller = TextEditingController(text: current);

    final chosen = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${provider.name} model'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (provider is OllamaProvider)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    installed.isEmpty
                        ? 'Ollama is not reachable — showing suggestions only.'
                        : '${installed.length} installed locally.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final m in options)
                      RadioListTile<String>(
                        value: m,
                        // ignore: deprecated_member_use
                        groupValue: current,
                        dense: true,
                        title: Text(m, style: const TextStyle(fontSize: 13)),
                        subtitle: installed.contains(m)
                            ? const Text('installed',
                                style: TextStyle(fontSize: 10))
                            : null,
                        // ignore: deprecated_member_use
                        onChanged: (v) => Navigator.pop(context, v),
                      ),
                  ],
                ),
              ),
              const Divider(),
              TextField(
                controller: controller,
                decoration: const InputDecoration(
                  labelText: 'Or type any model name',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (v) => Navigator.pop(context, v.trim()),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Use this'),
          ),
        ],
      ),
    );
    if (chosen == null || chosen.isEmpty) return;
    await widget.settings.setModelFor(provider.id, chosen);
    if (mounted) setState(() {});
  }

  /// The library location is always the user's choice — nothing about it is
  /// baked into the build.
  Future<void> _changeLibraryFolder() async {
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose your book library folder',
      initialDirectory: widget.settings.libraryPath,
    );
    if (path == null) return;
    await widget.settings.setLibraryPath(path);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Library folder set to $path')),
    );
  }

  Future<void> _clearCaches() async {
    await CoverService.clear();
    await OcrService.clear();
    await SummaryCache.clear();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Caches cleared')),
    );
  }

  void _openModelManager() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ModelManagerSheet(settings: widget.settings),
    ).then((_) => mounted ? setState(() {}) : null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = widget.settings.providerId;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
            child: Text('Appearance', style: theme.textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(
                  value: ThemeMode.light,
                  icon: Icon(Icons.light_mode_outlined),
                  label: Text('Light'),
                ),
                ButtonSegment(
                  value: ThemeMode.system,
                  icon: Icon(Icons.brightness_auto_outlined),
                  label: Text('System'),
                ),
                ButtonSegment(
                  value: ThemeMode.dark,
                  icon: Icon(Icons.dark_mode_outlined),
                  label: Text('Dark'),
                ),
              ],
              selected: {widget.theme.mode},
              onSelectionChanged: (s) => widget.theme.setMode(s.first),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Wrap(
              spacing: 12,
              runSpacing: 10,
              children: [
                for (final accent in AccentColour.values)
                  Tooltip(
                    message: accent.label,
                    child: InkWell(
                      onTap: () => widget.theme.setAccent(accent),
                      borderRadius: BorderRadius.circular(22),
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: accent.seed,
                          shape: BoxShape.circle,
                          border: widget.theme.accent == accent
                              ? Border.all(
                                  color: theme.colorScheme.onSurface, width: 2.5)
                              : null,
                        ),
                        child: widget.theme.accent == accent
                            ? const Icon(Icons.check,
                                size: 16, color: Colors.white)
                            : null,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          SwitchListTile(
            title: const Text('High contrast'),
            subtitle: const Text(
              'Stronger separation between surfaces and text.',
              style: TextStyle(fontSize: 12),
            ),
            value: widget.theme.highContrast,
            onChanged: (v) => widget.theme.setHighContrast(v),
          ),
          const Divider(height: 32),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
            child: Text('AI provider', style: theme.textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text(
              'Only used for textbooks, and only when you tap Summarise. '
              'Storybooks never contact a model. '
              'This machine has ${SystemInfo.ramLabel}.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ),
          for (final p in kProviders) _providerTile(p, selected),
          const Divider(height: 32),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('Library', style: theme.textTheme.titleMedium),
          ),
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: const Text('Library folder'),
            subtitle: Text(
              widget.settings.libraryPath ?? 'Not set — tap to choose',
              style: const TextStyle(fontSize: 12),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _changeLibraryFolder,
          ),
          ListTile(
            leading: const Icon(Icons.cleaning_services_outlined),
            title: const Text('Clear caches'),
            subtitle: const Text(
              'Covers, recognised text and saved summaries. '
              'Bookmarks, notes and progress are kept.',
              style: TextStyle(fontSize: 12),
            ),
            onTap: _clearCaches,
          ),
        ],
      ),
    );
  }

  Widget _providerTile(LlmProvider p, String selected) {
    final theme = Theme.of(context);
    final available = p.isAvailableOnThisPlatform;
    final hasKey = _hasKey[p.id] ?? false;
    final model = widget.settings.modelFor(p.id) ?? p.defaultModel;

    return RadioListTile<String>(
      value: p.id,
      groupValue: selected,
      // Ollama on a phone has nothing to connect to, so it cannot be selected there.
      onChanged: available
          ? (v) async {
              if (v == null) return;
              await widget.settings.setProviderId(v);
              setState(() {});
            }
          : null,
      title: Row(
        children: [
          Text(p.name),
          const SizedBox(width: 8),
          if (!p.isCloud)
            _Tag(label: 'local', color: theme.colorScheme.secondaryContainer)
          else
            _Tag(label: 'cloud', color: theme.colorScheme.tertiaryContainer),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            !available
                ? 'Not available on this platform — needs a local daemon'
                : p.keyName == null
                    ? 'No API key needed · $model'
                    : hasKey
                        ? 'Key saved · $model'
                        : 'No key yet · $model',
            style: theme.textTheme.bodySmall,
          ),
          if (available)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: 8,
                children: [
                  if (p.keyName != null)
                    OutlinedButton(
                      style: _tiny,
                      onPressed: () => _editKey(p),
                      child: Text(hasKey ? 'Change key' : 'Add key'),
                    ),
                  OutlinedButton(
                    style: _tiny,
                    onPressed: p is OllamaProvider
                        ? _openModelManager
                        : () => _editModel(p),
                    child: Text(p is OllamaProvider ? 'Manage models' : 'Model'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static final _tiny = OutlinedButton.styleFrom(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    minimumSize: const Size(0, 32),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    textStyle: const TextStyle(fontSize: 12),
  );
}

class _Tag extends StatelessWidget {
  final String label;
  final Color color;
  const _Tag({required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label, style: const TextStyle(fontSize: 11)),
      );
}
