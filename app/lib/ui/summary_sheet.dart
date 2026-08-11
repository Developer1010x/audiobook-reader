import 'package:flutter/material.dart';

import '../models/book.dart';
import '../services/llm/ai_mode.dart';
import '../services/llm/llm_provider.dart';
import '../services/llm/llm_error.dart';
import '../services/llm/summariser.dart';
import '../services/llm/usage_ledger.dart';
import '../services/llm/summary_length.dart';
import '../services/ocr_service.dart';
import '../services/reader_service.dart';
import '../services/settings_service.dart';
import '../services/tts_service.dart';
import 'widgets/markdown_text.dart';

/// The only place in the app that contacts an LLM. Reached solely from a
/// textbook, and only when the user asks for it.
class SummarySheet extends StatefulWidget {
  final Book book;
  final SettingsService settings;
  final int initialPage;
  final int pageCount;

  /// Supplies the text for a page range. PDFs use the PDF pipeline (with OCR);
  /// txt/md/epub pass their already-loaded pages in here.
  final Future<String> Function(int start, int end)? textProvider;

  /// True when docked beside the page rather than presented as a sheet.
  ///
  /// A docked panel owns no scroll sheet of its own and needs no title — its
  /// host supplies both — so the layout differs enough to be worth a flag
  /// rather than a second widget that would drift out of sync.
  final bool embedded;

  const SummarySheet({
    super.key,
    required this.book,
    required this.settings,
    required this.initialPage,
    required this.pageCount,
    this.textProvider,
    this.embedded = false,
  });

  @override
  State<SummarySheet> createState() => _SummarySheetState();
}

class _SummarySheetState extends State<SummarySheet> {
  late int _start = widget.initialPage;
  late int _end = widget.initialPage;
  late AiMode _mode = widget.settings.aiMode;
  late SummaryLength _length = widget.settings.summaryLength;

  bool _running = false;
  String? _result;
  String? _error;
  String? _stage;
  int? _charCount;

  final _tts = TtsService();
  CancellationToken? _cancel;
  UsageLedger? _ledger;

  @override
  void initState() {
    super.initState();
    UsageLedger.load().then((l) {
      if (mounted) setState(() => _ledger = l);
    });
  }

  LlmProvider get _provider => providerById(widget.settings.providerId);

  Future<void> _run() async {
    setState(() {
      _running = true;
      _error = null;
      _result = null;
      _stage = 'Reading pages $_start–$_end…';
    });
    try {
      // OCR runs automatically here: a scanned chapter should still be usable,
      // and the user has already opted into waiting by pressing the button.
      final text = widget.textProvider != null
          ? await widget.textProvider!(_start, _end)
          : await ReaderService.rangeText(
              widget.book,
              _start,
              _end,
              ocrFallback: await OcrService.isAvailable(),
              onProgress: (stage) {
                if (mounted) setState(() => _stage = stage);
              },
            );
      if (text.trim().isEmpty) {
        throw const InvalidRequest(
          'No text on those pages, and OCR could not read them either.',
        );
      }
      final provider = _provider;
      final key = provider.keyName == null
          ? null
          : await widget.settings.getKey(provider.keyName!);
      final model = widget.settings.modelFor(provider.id) ?? provider.defaultModel;

      if (!mounted) return;
      setState(() {
        _charCount = text.length;
        _stage = '${_mode.label} via ${provider.name}…';
      });

      // Summariser chunks when the text exceeds the provider's context, so a
      // whole chapter is summarised properly instead of silently truncated.
      final token = CancellationToken();
      _cancel = token;

      // Streamed output: the answer appears as it is generated rather than
      // after it completes.
      final buffer = StringBuffer();
      final out = await Summariser.run(
        provider: provider,
        text: text,
        mode: _mode,
        length: _length,
        model: model,
        apiKey: key,
        cancel: token,
        ledger: _ledger,
        onProgress: (stage) {
          if (mounted) setState(() => _stage = stage);
        },
        onDelta: (delta) {
          buffer.write(delta);
          if (mounted) setState(() => _result = buffer.toString());
        },
      );
      if (!mounted) return;
      setState(() {
        _result = out;
        _running = false;
        _stage = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _running = false;
        _stage = null;
      });
    }
  }

  @override
  void dispose() {
    // Closing the sheet must stop work nobody will see — on a cloud provider
    // that is money still being spent.
    _cancel?.cancel();
    _tts.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = _provider;

    if (widget.embedded) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: _body(theme, provider),
      );
    }

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      maxChildSize: 0.95,
      builder: (context, scrollController) => ListView(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
        children: [
          Text('AI assist', style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(widget.book.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline)),
          const SizedBox(height: 18),
          ..._body(theme, provider),
        ],
      ),
    );
  }

  /// The controls and output, shared by the docked panel and the sheet so the
  /// two presentations cannot drift apart.
  List<Widget> _body(ThemeData theme, LlmProvider provider) {
    return [
          // What to do with the passage — the same pages serve very different
          // purposes, so this is the first choice, not a buried setting.
          Text('What do you need?', style: theme.textTheme.labelLarge),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final mode in AiMode.values)
                ChoiceChip(
                  avatar: Icon(
                    IconData(mode.icon, fontFamily: 'MaterialIcons'),
                    size: 16,
                  ),
                  label: Text(mode.label),
                  selected: _mode == mode,
                  onSelected: (_) {
                    setState(() => _mode = mode);
                    widget.settings.setAiMode(mode);
                  },
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _mode.description,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
          const SizedBox(height: 18),

          Text('How long?', style: theme.textTheme.labelLarge),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final len in SummaryLength.values)
                ChoiceChip(
                  label: Text(len.label),
                  selected: _length == len,
                  onSelected: (_) {
                    setState(() => _length = len);
                    widget.settings.setSummaryLength(len);
                  },
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _length.hint,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
          const SizedBox(height: 18),

          _PrivacyBanner(provider: provider, charCount: _charCount),
          const SizedBox(height: 16),

          Row(
            children: [
              Expanded(child: _pageField('From', _start, (v) => setState(() => _start = v))),
              const SizedBox(width: 12),
              Expanded(child: _pageField('To', _end, (v) => setState(() => _end = v))),
            ],
          ),
          const SizedBox(height: 16),

          if (_running)
            OutlinedButton.icon(
              onPressed: () {
                _cancel?.cancel();
                setState(() { _running = false; _stage = 'Cancelled.'; });
              },
              icon: const Icon(Icons.stop, size: 18),
              label: const Text('Stop'),
            )
          else
          FilledButton.icon(
            onPressed: _running ? null : _run,
            icon: _running
                ? const SizedBox(
                    width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.auto_awesome, size: 18),
            label: Text(_running ? 'Working…' : '${_mode.label} · ${provider.name}'),
          ),

          if (_stage != null) ...[
            const SizedBox(height: 10),
            Text(_stage!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
          ],

          if (_error != null) ...[
            const SizedBox(height: 20),
            Card(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Text(_error!,
                    style: TextStyle(color: theme.colorScheme.onErrorContainer)),
              ),
            ),
          ],

          if (_result != null) ...[
            const SizedBox(height: 20),
            Row(
              children: [
                Text(_mode.label, style: theme.textTheme.titleMedium),
                const Spacer(),
                IconButton(
                  icon: Icon(_tts.isSpeaking ? Icons.stop : Icons.volume_up),
                  tooltip: 'Read this aloud',
                  onPressed: () => _tts.isSpeaking
                      ? _tts.stop()
                      : _tts.speak(MarkdownText.toSpeech(_result!)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Models answer in Markdown, and the prompts ask for that structure
            // because it is what makes a summary scannable. Showing the raw
            // asterisks threw that away.
            MarkdownText(_result!),
          ],
    ];
  }

  Widget _pageField(String label, int value, ValueChanged<int> onChanged) {
    return TextFormField(
      initialValue: '$value',
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        helperText: '1–${widget.pageCount}',
      ),
      onChanged: (v) {
        final n = int.tryParse(v);
        if (n != null && n >= 1 && n <= widget.pageCount) onChanged(n);
      },
    );
  }
}

class _PrivacyBanner extends StatelessWidget {
  final LlmProvider provider;
  final int? charCount;
  const _PrivacyBanner({required this.provider, this.charCount});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cloud = provider.isCloud;
    final color = cloud
        ? theme.colorScheme.tertiaryContainer
        : theme.colorScheme.secondaryContainer;
    final onColor = cloud
        ? theme.colorScheme.onTertiaryContainer
        : theme.colorScheme.onSecondaryContainer;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(cloud ? Icons.cloud_upload_outlined : Icons.lock_outline,
              size: 18, color: onColor),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              cloud
                  ? 'This sends the selected pages'
                      '${charCount != null ? " ($charCount characters)" : ""} '
                      'to ${provider.name}. The text leaves this device.'
                  : 'Runs on this device via ${provider.name}. '
                      'No page text leaves the machine.',
              style: theme.textTheme.bodySmall?.copyWith(color: onColor),
            ),
          ),
        ],
      ),
    );
  }
}
