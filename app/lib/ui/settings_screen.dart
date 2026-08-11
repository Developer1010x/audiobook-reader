import 'package:flutter/material.dart';

import '../services/llm/llm_provider.dart';
import '../services/settings_service.dart';

class SettingsScreen extends StatefulWidget {
  final SettingsService settings;
  const SettingsScreen({super.key, required this.settings});

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
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
            child: Text('AI provider', style: theme.textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text(
              'Only used for textbooks, and only when you tap Summarise. '
              'Storybooks never contact a model.',
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
            subtitle: Text(widget.settings.libraryPath ?? 'Not set'),
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
                    onPressed: () => _editModel(p),
                    child: const Text('Model'),
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
