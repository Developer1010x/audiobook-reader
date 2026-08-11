import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:http/http.dart' as http;

import 'ai_mode.dart';
import 'llm_error.dart';
import 'summary_length.dart';

/// A completed generation, with enough accounting to price it.
class LlmResult {
  const LlmResult({
    required this.text,
    this.inputTokens = 0,
    this.outputTokens = 0,
  });

  final String text;
  final int inputTokens;
  final int outputTokens;

  LlmResult operator +(LlmResult other) => LlmResult(
        text: other.text,
        inputTokens: inputTokens + other.inputTokens,
        outputTokens: outputTokens + other.outputTokens,
      );
}

/// Called with each new fragment as it arrives.
typedef TokenSink = void Function(String delta);

/// One LLM backend. Everything the UI needs to decide whether to offer it, warn
/// about it, or ask for a key is declared here rather than special-cased in widgets.
abstract class LlmProvider {
  const LlmProvider();

  String get id;
  String get name;
  String get defaultModel;
  List<String> get suggestedModels;

  /// True when text leaves the device. Drives the warning banner in the UI.
  bool get isCloud;

  /// Env var / stored-key name. Null for providers that need no key (Ollama).
  String? get keyName;

  /// False where the provider cannot work at all — Ollama on mobile, since there
  /// is no localhost daemon on iOS or Android.
  bool get isAvailableOnThisPlatform => true;

  String? get keyUrl;

  /// Usable context in *tokens*, stated conservatively.
  ///
  /// Erring high is the dangerous direction: the model silently sees only part
  /// of the input and answers confidently about text it never read.
  int get contextTokens;

  /// Characters we are willing to send as input in one request. Roughly 3.6
  /// characters per token, and only ~55% of the window — the prompt and the
  /// answer need the rest.
  int get inputCharBudget => (contextTokens * 0.55 * 3.6).round();

  /// How many requests this provider tolerates in parallel. Local inference is
  /// serial by nature (one GPU/CPU); hosted APIs are happy with a few.
  int get maxConcurrency => isCloud ? 4 : 1;

  Future<LlmResult> generate(
    String text, {
    String? model,
    String? apiKey,
    AiMode mode = AiMode.summary,
    SummaryLength length = SummaryLength.standard,
    String? promptOverride,
    TokenSink? onDelta,
    CancellationToken? cancel,
  });

  /// Convenience for callers that only want the text.
  Future<String> summarise(
    String text, {
    String? model,
    String? apiKey,
    AiMode mode = AiMode.summary,
    SummaryLength length = SummaryLength.standard,
    String? promptOverride,
  }) async =>
      (await generate(text,
              model: model,
              apiKey: apiKey,
              mode: mode,
              length: length,
              promptOverride: promptOverride))
          .text;
}

/// The prompt actually sent: instruction + length constraint + text.
///
/// A one-line answer overrides the mode's shape entirely — "one-line flashcards"
/// is incoherent, so the mode prompt is dropped rather than fought with.
String buildPrompt(
  String text, {
  AiMode mode = AiMode.summary,
  SummaryLength length = SummaryLength.standard,
  String? promptOverride,
}) {
  final instruction = promptOverride ??
      (length.overridesShape
          ? 'Summarise the following passage from a book.'
          : mode.prompt.replaceAll('{n}', '${length.count}'));
  return '$instruction\n\n${length.instruction}\n\n---\n\n$text';
}

/// Rough token estimate for accounting when a provider does not report usage.
int estimateTokens(String text) => (text.length / 3.6).ceil();

/// Kept for callers that catch a single type. Every concrete failure is one of
/// the [LlmError] subclasses.
typedef LlmException = LlmError;

// ── streaming plumbing ───────────────────────────────────────────────

/// Streams an OpenAI-compatible `/chat/completions` SSE response.
///
/// Groq, OpenRouter, Together and Hugging Face all speak this shape, so one
/// implementation covers four providers.
Future<LlmResult> openAiCompatible({
  required String baseUrl,
  required String model,
  required String apiKey,
  required String prompt,
  required String providerName,
  Map<String, String> extraHeaders = const {},
  TokenSink? onDelta,
  CancellationToken? cancel,
}) async {
  if (apiKey.isEmpty) {
    throw AuthFailed('needs an API key. Add one in Settings.',
        provider: providerName);
  }
  cancel?.throwIfCancelled();

  final client = http.Client();
  try {
    final request = http.Request('POST', Uri.parse('$baseUrl/chat/completions'))
      ..headers.addAll({
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
        ...extraHeaders,
      })
      ..body = jsonEncode({
        'model': model,
        'messages': [
          {'role': 'user', 'content': prompt},
        ],
        // Low but not zero: summarising should be faithful, not creative.
        'temperature': 0.3,
        'stream': true,
        'stream_options': {'include_usage': true},
      });

    final http.StreamedResponse response;
    try {
      response = await client.send(request);
    } catch (e) {
      throw TransportFailure('$e', provider: providerName);
    }

    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      throw errorForStatus(response.statusCode, body, providerName);
    }

    final buffer = StringBuffer();
    var inputTokens = 0;
    var outputTokens = 0;

    await for (final line in response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (cancel?.isCancelled ?? false) throw const Cancelled();
      if (!line.startsWith('data:')) continue;

      final payload = line.substring(5).trim();
      if (payload.isEmpty || payload == '[DONE]') continue;

      try {
        final chunk = jsonDecode(payload) as Map<String, dynamic>;
        final usage = chunk['usage'] as Map<String, dynamic>?;
        if (usage != null) {
          inputTokens = (usage['prompt_tokens'] as num?)?.toInt() ?? inputTokens;
          outputTokens =
              (usage['completion_tokens'] as num?)?.toInt() ?? outputTokens;
        }
        final choices = chunk['choices'] as List?;
        if (choices == null || choices.isEmpty) continue;
        final delta = choices.first['delta']?['content'] as String?;
        if (delta != null && delta.isNotEmpty) {
          buffer.write(delta);
          onDelta?.call(delta);
        }
      } catch (_) {
        continue; // a malformed frame should not kill the stream
      }
    }

    final text = buffer.toString().trim();
    if (text.isEmpty) {
      throw EmptyResponse('returned an empty response.', provider: providerName);
    }
    return LlmResult(
      text: text,
      inputTokens: inputTokens > 0 ? inputTokens : estimateTokens(prompt),
      outputTokens: outputTokens > 0 ? outputTokens : estimateTokens(text),
    );
  } finally {
    client.close();
  }
}

// ─────────────────────────── Local ───────────────────────────

/// Ollama. The private option: text never leaves the machine. Desktop only —
/// there is no localhost daemon to talk to on a phone.
class OllamaProvider extends LlmProvider {
  const OllamaProvider();

  @override
  String get id => 'ollama';
  @override
  String get name => 'Ollama (local)';
  @override
  String get defaultModel => 'qwen2.5:1.5b';
  @override
  List<String> get suggestedModels => ['qwen2.5:1.5b', 'llama3.2', 'mistral', 'phi3'];
  @override
  bool get isCloud => false;
  @override
  String? get keyName => null;
  @override
  String? get keyUrl => 'https://ollama.com/download';

  /// Requested explicitly via `num_ctx` below. Ollama's own default is only
  /// 2048–4096 regardless of what the model supports, which silently truncated
  /// every multi-page summary before this was set.
  @override
  int get contextTokens => 8192;

  @override
  bool get isAvailableOnThisPlatform =>
      Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  /// Models actually pulled on this machine.
  ///
  /// The hard-coded suggestions are a guess; this is the truth. Offering a
  /// model that is not installed just produces a 404 at generation time.
  static Future<List<String>> installedModels() async {
    try {
      final resp = await http
          .get(Uri.parse('http://localhost:11434/api/tags'))
          .timeout(const Duration(seconds: 3));
      if (resp.statusCode != 200) return const [];
      final models = (jsonDecode(resp.body)['models'] as List?) ?? const [];
      return models
          .map((m) => (m as Map)['name'] as String?)
          .whereType<String>()
          .toList()
        ..sort();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<LlmResult> generate(
    String text, {
    String? model,
    String? apiKey,
    AiMode mode = AiMode.summary,
    SummaryLength length = SummaryLength.standard,
    String? promptOverride,
    TokenSink? onDelta,
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    final m = model ?? defaultModel;
    final prompt = buildPrompt(text,
        mode: mode, length: length, promptOverride: promptOverride);

    final client = http.Client();
    try {
      final request =
          http.Request('POST', Uri.parse('http://localhost:11434/api/generate'))
            ..headers['Content-Type'] = 'application/json'
            ..body = jsonEncode({
              'model': m,
              'prompt': prompt,
              'stream': true,
              'options': {
                // Without this Ollama uses its small default and quietly drops
                // the rest of the prompt.
                'num_ctx': contextTokens,
                'temperature': 0.3,
              },
            });

      final http.StreamedResponse response;
      try {
        response = await client.send(request);
      } catch (e) {
        throw const TransportFailure(
          'Could not reach Ollama at localhost:11434. Is `ollama serve` running?',
          provider: 'Ollama',
        );
      }

      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        if (response.statusCode == 404) {
          throw ModelUnavailable('Model "$m" is not pulled. Run: ollama pull $m',
              provider: 'Ollama');
        }
        throw errorForStatus(response.statusCode, body, 'Ollama');
      }

      final buffer = StringBuffer();
      var inputTokens = 0;
      var outputTokens = 0;

      // Ollama streams newline-delimited JSON rather than SSE.
      await for (final line in response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (cancel?.isCancelled ?? false) throw const Cancelled();
        if (line.trim().isEmpty) continue;
        try {
          final chunk = jsonDecode(line) as Map<String, dynamic>;
          final delta = chunk['response'] as String?;
          if (delta != null && delta.isNotEmpty) {
            buffer.write(delta);
            onDelta?.call(delta);
          }
          if (chunk['done'] == true) {
            inputTokens = (chunk['prompt_eval_count'] as num?)?.toInt() ?? 0;
            outputTokens = (chunk['eval_count'] as num?)?.toInt() ?? 0;
          }
        } catch (_) {
          continue;
        }
      }

      final out = buffer.toString().trim();
      if (out.isEmpty) {
        throw const EmptyResponse('returned an empty response.',
            provider: 'Ollama');
      }
      return LlmResult(
        text: out,
        inputTokens: inputTokens > 0 ? inputTokens : estimateTokens(prompt),
        outputTokens: outputTokens > 0 ? outputTokens : estimateTokens(out),
      );
    } finally {
      client.close();
    }
  }
}

// ─────────────────────────── Cloud ───────────────────────────

class GeminiProvider extends LlmProvider {
  const GeminiProvider();

  @override
  String get id => 'gemini';
  @override
  String get name => 'Google Gemini';
  @override
  String get defaultModel => 'gemini-2.5-flash';
  @override
  List<String> get suggestedModels =>
      ['gemini-2.5-flash', 'gemini-2.5-pro', 'gemini-2.0-flash'];
  @override
  bool get isCloud => true;
  @override
  String? get keyName => 'GEMINI_API_KEY';
  @override
  String? get keyUrl => 'https://aistudio.google.com/apikey';

  /// Gemini advertises far more; this is a deliberate cap so a single request
  /// never becomes enormous and slow.
  @override
  int get contextTokens => 120000;

  @override
  Future<LlmResult> generate(
    String text, {
    String? model,
    String? apiKey,
    AiMode mode = AiMode.summary,
    SummaryLength length = SummaryLength.standard,
    String? promptOverride,
    TokenSink? onDelta,
    CancellationToken? cancel,
  }) async {
    if (apiKey == null || apiKey.isEmpty) {
      throw const AuthFailed('needs an API key. Add one in Settings.',
          provider: 'Gemini');
    }
    cancel?.throwIfCancelled();

    final m = model ?? defaultModel;
    final prompt = buildPrompt(text,
        mode: mode, length: length, promptOverride: promptOverride);

    final client = http.Client();
    try {
      final uri = Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/$m:streamGenerateContent?alt=sse');
      final request = http.Request('POST', uri)
        ..headers.addAll({
          'Content-Type': 'application/json',
          'x-goog-api-key': apiKey,
        })
        ..body = jsonEncode({
          'contents': [
            {
              'parts': [
                {'text': prompt}
              ]
            }
          ],
          'generationConfig': {'temperature': 0.3},
        });

      final http.StreamedResponse response;
      try {
        response = await client.send(request);
      } catch (e) {
        throw TransportFailure('$e', provider: 'Gemini');
      }

      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        throw errorForStatus(response.statusCode, body, 'Gemini');
      }

      final buffer = StringBuffer();
      var inputTokens = 0;
      var outputTokens = 0;

      await for (final line in response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (cancel?.isCancelled ?? false) throw const Cancelled();
        if (!line.startsWith('data:')) continue;
        final payload = line.substring(5).trim();
        if (payload.isEmpty) continue;
        try {
          final chunk = jsonDecode(payload) as Map<String, dynamic>;
          final usage = chunk['usageMetadata'] as Map<String, dynamic>?;
          if (usage != null) {
            inputTokens =
                (usage['promptTokenCount'] as num?)?.toInt() ?? inputTokens;
            outputTokens =
                (usage['candidatesTokenCount'] as num?)?.toInt() ?? outputTokens;
          }
          final candidates = chunk['candidates'] as List?;
          if (candidates == null || candidates.isEmpty) continue;
          final parts = candidates.first['content']?['parts'] as List? ?? [];
          for (final part in parts) {
            final delta = part['text'] as String?;
            if (delta != null && delta.isNotEmpty) {
              buffer.write(delta);
              onDelta?.call(delta);
            }
          }
        } catch (_) {
          continue;
        }
      }

      final out = buffer.toString().trim();
      if (out.isEmpty) {
        // Usually a safety block — surface it rather than returning blank.
        throw const EmptyResponse(
            'returned nothing — the request may have been blocked.',
            provider: 'Gemini');
      }
      return LlmResult(
        text: out,
        inputTokens: inputTokens > 0 ? inputTokens : estimateTokens(prompt),
        outputTokens: outputTokens > 0 ? outputTokens : estimateTokens(out),
      );
    } finally {
      client.close();
    }
  }
}

/// Base for the four OpenAI-compatible hosted providers.
abstract class _OpenAiCompatibleProvider extends LlmProvider {
  const _OpenAiCompatibleProvider();

  String get baseUrl;
  Map<String, String> get extraHeaders => const {};

  @override
  bool get isCloud => true;

  @override
  Future<LlmResult> generate(
    String text, {
    String? model,
    String? apiKey,
    AiMode mode = AiMode.summary,
    SummaryLength length = SummaryLength.standard,
    String? promptOverride,
    TokenSink? onDelta,
    CancellationToken? cancel,
  }) =>
      openAiCompatible(
        baseUrl: baseUrl,
        model: model ?? defaultModel,
        apiKey: apiKey ?? '',
        prompt: buildPrompt(text,
            mode: mode, length: length, promptOverride: promptOverride),
        providerName: name,
        extraHeaders: extraHeaders,
        onDelta: onDelta,
        cancel: cancel,
      );
}

/// Groq — open models (Llama, Qwen), free tier, very fast.
class GroqProvider extends _OpenAiCompatibleProvider {
  const GroqProvider();

  @override
  String get id => 'groq';
  @override
  String get name => 'Groq';
  @override
  String get baseUrl => 'https://api.groq.com/openai/v1';
  @override
  String get defaultModel => 'llama-3.3-70b-versatile';
  @override
  List<String> get suggestedModels =>
      ['llama-3.3-70b-versatile', 'llama-3.1-8b-instant', 'qwen-2.5-32b'];
  @override
  String? get keyName => 'GROQ_API_KEY';
  @override
  String? get keyUrl => 'https://console.groq.com/keys';
  @override
  int get contextTokens => 32000;
}

/// OpenRouter — one key, hundreds of models, many open and free.
class OpenRouterProvider extends _OpenAiCompatibleProvider {
  const OpenRouterProvider();

  @override
  String get id => 'openrouter';
  @override
  String get name => 'OpenRouter';
  @override
  String get baseUrl => 'https://openrouter.ai/api/v1';
  @override
  Map<String, String> get extraHeaders => const {'X-Title': 'audiobook-reader'};
  @override
  String get defaultModel => 'meta-llama/llama-3.3-70b-instruct:free';
  @override
  List<String> get suggestedModels => [
        'meta-llama/llama-3.3-70b-instruct:free',
        'qwen/qwen-2.5-72b-instruct',
        'deepseek/deepseek-chat',
        'mistralai/mistral-small',
      ];
  @override
  String? get keyName => 'OPENROUTER_API_KEY';
  @override
  String? get keyUrl => 'https://openrouter.ai/keys';

  /// Varies wildly by model, so this is the conservative floor.
  @override
  int get contextTokens => 32000;
}

/// Together AI — open models, paid.
class TogetherProvider extends _OpenAiCompatibleProvider {
  const TogetherProvider();

  @override
  String get id => 'together';
  @override
  String get name => 'Together AI';
  @override
  String get baseUrl => 'https://api.together.xyz/v1';
  @override
  String get defaultModel => 'meta-llama/Llama-3.3-70B-Instruct-Turbo';
  @override
  List<String> get suggestedModels => [
        'meta-llama/Llama-3.3-70B-Instruct-Turbo',
        'Qwen/Qwen2.5-72B-Instruct-Turbo',
        'deepseek-ai/DeepSeek-V3',
      ];
  @override
  String? get keyName => 'TOGETHER_API_KEY';
  @override
  String? get keyUrl => 'https://api.together.xyz/settings/api-keys';
  @override
  int get contextTokens => 32000;
}

/// Hugging Face router — open models, free tier is rate-limited.
class HuggingFaceProvider extends _OpenAiCompatibleProvider {
  const HuggingFaceProvider();

  @override
  String get id => 'huggingface';
  @override
  String get name => 'Hugging Face';
  @override
  String get baseUrl => 'https://router.huggingface.co/v1';
  @override
  String get defaultModel => 'meta-llama/Llama-3.1-8B-Instruct';
  @override
  List<String> get suggestedModels => [
        'meta-llama/Llama-3.1-8B-Instruct',
        'Qwen/Qwen2.5-7B-Instruct',
        'mistralai/Mistral-7B-Instruct-v0.3',
      ];
  @override
  String? get keyName => 'HF_TOKEN';
  @override
  String? get keyUrl => 'https://huggingface.co/settings/tokens';
  @override
  int get contextTokens => 16000;
}

/// Every provider the app knows about. Ollama is first so it is the default.
const kProviders = <LlmProvider>[
  OllamaProvider(),
  GeminiProvider(),
  GroqProvider(),
  OpenRouterProvider(),
  TogetherProvider(),
  HuggingFaceProvider(),
];

LlmProvider providerById(String id) =>
    kProviders.firstWhere((p) => p.id == id, orElse: () => kProviders.first);

String? defaultModelFor(String provider) => providerById(provider).defaultModel;
