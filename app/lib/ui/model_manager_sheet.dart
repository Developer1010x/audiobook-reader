import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/llm/llm_error.dart';
import '../services/llm/ollama_manager.dart';
import '../services/settings_service.dart';
import '../services/system_info.dart';

/// Install and choose local models.
///
/// Models the machine cannot hold are shown but disabled, with the reason
/// stated — a hard hide would leave the user wondering why a model they read
/// about is missing, and RAM detection is not reliable enough to be silently
/// authoritative.
class ModelManagerSheet extends StatefulWidget {
  final SettingsService settings;
  const ModelManagerSheet({super.key, required this.settings});

  @override
  State<ModelManagerSheet> createState() => _ModelManagerSheetState();
}

class _ModelManagerSheetState extends State<ModelManagerSheet> {
  List<InstalledModel> _installed = const [];
  bool _running = false;
  bool _loading = true;

  String? _pulling;
  PullProgress? _progress;
  CancellationToken? _cancel;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final running = await OllamaManager.isRunning();
    final installed = running ? await OllamaManager.installed() : <InstalledModel>[];
    if (!mounted) return;
    setState(() {
      _running = running;
      _installed = installed;
      _loading = false;
    });
  }

  bool _isInstalled(String name) => _installed.any(
        (m) => m.name == name || m.name == '$name:latest' || '${m.name}:latest' == name,
      );

  Future<void> _pull(ModelOption option) async {
    final token = CancellationToken();
    setState(() {
      _pulling = option.name;
      _progress = null;
      _error = null;
      _cancel = token;
    });
    try {
      await OllamaManager.pull(
        option.name,
        cancel: token,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      await _refresh();
      if (!mounted) return;
      // A freshly pulled model is almost certainly the one they want to use.
      await widget.settings.setModelFor('ollama', option.name);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${option.label} installed and selected')),
      );
    } on Cancelled {
      // Ollama keeps partial layers, so resuming later is cheap.
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) {
        setState(() {
          _pulling = null;
          _progress = null;
          _cancel = null;
        });
      }
    }
  }

  Future<void> _delete(String name) async {
    await OllamaManager.delete(name);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ram = SystemInfo.totalRamMb;
    final selected = widget.settings.modelFor('ollama');

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
        children: [
          Text('Local models', style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Local models keep book text on this machine. '
            'This computer has ${SystemInfo.ramLabel}.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
          const SizedBox(height: 18),

          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (!_running)
            _OllamaMissing(onRecheck: _refresh)
          else ...[
            if (_error != null) ...[
              Card(
                color: theme.colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Text(_error!,
                      style: TextStyle(
                          color: theme.colorScheme.onErrorContainer)),
                ),
              ),
              const SizedBox(height: 12),
            ],
            for (final option in OllamaManager.catalogue)
              _ModelRow(
                option: option,
                installed: _isInstalled(option.name),
                selected: selected == option.name,
                fits: option.fitsOn(ram),
                recommended: OllamaManager.recommended().name == option.name,
                pulling: _pulling == option.name,
                progress: _pulling == option.name ? _progress : null,
                busy: _pulling != null,
                onPull: () => _pull(option),
                onCancel: () => _cancel?.cancel(),
                onUse: () async {
                  await widget.settings.setModelFor('ollama', option.name);
                  if (mounted) setState(() {});
                },
                onDelete: () => _delete(option.name),
              ),

            // Anything pulled outside the catalogue still deserves to be listed.
            ...(() {
              final extras = _installed
                  .where((m) => !OllamaManager.catalogue
                      .any((c) => m.name == c.name || m.name == '${c.name}:latest'))
                  .toList();
              if (extras.isEmpty) return <Widget>[];
              return [
                const SizedBox(height: 20),
                Text('Also installed', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                for (final m in extras)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(m.name, style: const TextStyle(fontSize: 13)),
                    subtitle: Text(m.sizeLabel),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (selected == m.name)
                          const Chip(label: Text('in use'))
                        else
                          TextButton(
                            onPressed: () async {
                              await widget.settings.setModelFor('ollama', m.name);
                              if (mounted) setState(() {});
                            },
                            child: const Text('Use'),
                          ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _delete(m.name),
                        ),
                      ],
                    ),
                  ),
              ];
            })(),
          ],
        ],
      ),
    );
  }
}

class _ModelRow extends StatelessWidget {
  const _ModelRow({
    required this.option,
    required this.installed,
    required this.selected,
    required this.fits,
    required this.recommended,
    required this.pulling,
    required this.progress,
    required this.busy,
    required this.onPull,
    required this.onCancel,
    required this.onUse,
    required this.onDelete,
  });

  final ModelOption option;
  final bool installed;
  final bool selected;
  final bool fits;
  final bool recommended;
  final bool pulling;
  final PullProgress? progress;
  final bool busy;
  final VoidCallback onPull;
  final VoidCallback onCancel;
  final VoidCallback onUse;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ramGb = (SystemInfo.totalRamMb ?? 0) / 1024;

    return Opacity(
      opacity: fits ? 1 : 0.55,
      child: Card(
        margin: const EdgeInsets.only(bottom: 10),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      children: [
                        Text(option.label,
                            style: theme.textTheme.bodyLarge
                                ?.copyWith(fontWeight: FontWeight.w600)),
                        if (selected)
                          const Chip(
                            label: Text('in use'),
                            visualDensity: VisualDensity.compact,
                          )
                        else if (recommended && fits)
                          Chip(
                            label: const Text('recommended'),
                            visualDensity: VisualDensity.compact,
                            backgroundColor: theme.colorScheme.primaryContainer,
                          ),
                      ],
                    ),
                  ),
                  if (pulling)
                    TextButton(onPressed: onCancel, child: const Text('Cancel'))
                  else if (installed)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!selected)
                          TextButton(onPressed: onUse, child: const Text('Use')),
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: 'Remove',
                          onPressed: busy ? null : onDelete,
                        ),
                      ],
                    )
                  else
                    FilledButton.tonalIcon(
                      icon: const Icon(Icons.download, size: 18),
                      label: Text('${option.downloadGb} GB'),
                      onPressed: busy || !fits ? null : onPull,
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                fits
                    ? '${option.note}  ·  needs ~${option.ramGb} GB RAM'
                    : 'Needs ~${option.ramGb} GB RAM — this machine has '
                        '${ramGb.toStringAsFixed(0)} GB',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: fits ? theme.colorScheme.outline : theme.colorScheme.error,
                ),
              ),
              if (pulling) ...[
                const SizedBox(height: 10),
                LinearProgressIndicator(value: progress?.fraction),
                const SizedBox(height: 4),
                Text(progress?.label ?? 'Starting…',
                    style: theme.textTheme.labelSmall),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown when Ollama is absent or not running.
///
/// The app does not install the daemon itself: that needs a system service and
/// admin rights, which an application should not be doing quietly.
class _OllamaMissing extends StatelessWidget {
  const _OllamaMissing({required this.onRecheck});
  final VoidCallback onRecheck;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final installed = OllamaManager.isInstalled;
    final command =
        installed ? OllamaManager.startCommand : OllamaManager.installCommand;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.info_outline, color: theme.colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                installed
                    ? 'Ollama is installed but not running.'
                    : 'Ollama is not installed.',
                style: theme.textTheme.titleSmall,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          installed
              ? 'Start it and local summarising becomes available.'
              : 'Install it to keep book text on this machine. Without it you '
                  'can still use a cloud provider, but page text will leave the '
                  'device.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline),
        ),
        const SizedBox(height: 14),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Expanded(
                child: SelectableText(
                  command,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy, size: 18),
                tooltip: 'Copy',
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: command));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Command copied')),
                  );
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        FilledButton.tonalIcon(
          onPressed: onRecheck,
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Check again'),
        ),
      ],
    );
  }
}
