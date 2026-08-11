import 'dart:convert';
import 'dart:io' show Platform;

import 'package:http/http.dart' as http;

import 'ai_mode.dart';
import 'summary_length.dart';

/// One LLM backend. Everything the UI needs to decide whether to offer it, warn
/// about it, or ask for a key is declared here rather than special-cased in widgets.
abstract class LlmProvider {
  const LlmProvider();

  String get id;
  String get name;

  /// Model used when the user hasn't chosen one.
  String get defaultModel;

  /// Models worth offering in a dropdown. Not exhaustive — the user can type one.
  List<String> get suggestedModels;

  /// True when text leaves the device. Drives the warning banner in the UI.
  bool get isCloud;

  /// Env var / stored-key name. Null for providers that need no key (Ollama).
  String? get keyName;

  /// False where the provider cannot work at all — Ollama on mobile, since there
  /// is no localhost daemon on iOS or Android.
  bool get isAvailableOnThisPlatform => true;

  /// Where to get a key, shown in settings.
  String? get keyUrl;

  /// Usable context in *tokens*, stated conservatively.
  ///
  /// This decides whether text must be chunked. Erring high is the dangerous
  /// direction: the model silently sees only part of the input and answers
  /// confidently about text it never read.
  int get contextTokens;

  /// Characters we are willing to send as input in one request.
  ///
  /// Roughly 3.6 characters per token for English prose, and only ~55% of the
  /// window is spent on input — the prompt and the answer need the rest.
  int get inputCharBudget => (contextTokens * 0.55 * 3.6).round();

  Future<String> summarise(
    String text, {
    String? model,
    String? apiKey,
    AiMode mode = AiMode.summary,
    SummaryLength length = SummaryLength.standard,

    /// Replaces the mode prompt entirely — used by the map and reduce stages.
    String? promptOverride,
  });
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

/// Thrown for every provider failure, so the UI has one thing to catch.
class LlmException implements Exception {
  final String message;
  const LlmException(this.message);
  @override
  String toString() => message;
}

/// Shared helper for the OpenAI-compatible `/chat/completions` shape, which
/// Groq, OpenRouter, Together and many others all speak. One implementation
/// covers four providers; only the base URL and key differ.
Future<String> openAiCompatible({
  required String baseUrl,
  required String model,
  required String apiKey,
  required String prompt,
  required String providerName,
  Map<String, String> extraHeaders = const {},
}) async {
  if (apiKey.isEmpty) {
    throw LlmException('$providerName needs an API key. Add one in Settings.');
  }
  final http.Response resp;
  try {
    resp = await http.post(
      Uri.parse('$baseUrl/chat/completions'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
        ...extraHeaders,
      },
      body: jsonEncode({
        'model': model,
        'messages': [
          {'role': 'user', 'content': prompt},
        ],
        // Low but not zero: summarising should be faithful, not creative.
        'temperature': 0.3,
      }),
    );
  } catch (e) {
    throw LlmException('Could not reach $providerName: $e');
  }
  if (resp.statusCode != 200) {
    throw LlmException(
      '$providerName error ${resp.statusCode}: ${_truncate(resp.body)}',
    );
  }
  final data = jsonDecode(resp.body) as Map<String, dynamic>;
  final choices = data['choices'] as List?;
  if (choices == null || choices.isEmpty) {
    throw LlmException('$providerName returned no choices: ${_truncate(resp.body)}');
  }
  final content = choices.first['message']?['content'] as String?;
  if (content == null || content.trim().isEmpty) {
    throw LlmException('$providerName returned an empty response.');
  }
  return content.trim();
}

String _truncate(String s) => s.length > 300 ? '${s.substring(0, 300)}…' : s;

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

  /// Requested explicitly below via `num_ctx`. Ollama's own default is only
  /// 2048–4096 regardless of what the model supports, which silently truncated
  /// every multi-page summary before this was set.
  @override
  int get contextTokens => 8192;

  @override
  bool get isAvailableOnThisPlatform =>
      Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  @override
  Future<String> summarise(
    String text, {
    String? model,
    String? apiKey,
    AiMode mode = AiMode.summary,
    SummaryLength length = SummaryLength.standard,
    String? promptOverride,
  }) async {
    final m = model ?? defaultModel;
    final http.Response resp;
    try {
      resp = await http.post(
        Uri.parse('http://localhost:11434/api/generate'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'model': m,
          'prompt': buildPrompt(text,
              mode: mode, length: length, promptOverride: promptOverride),
          'stream': false,
          'options': {
            // Without this Ollama uses its small default and quietly drops the
            // rest of the prompt.
            'num_ctx': contextTokens,
            'temperature': 0.3,
          },
        }),
      );
    } catch (e) {
      throw const LlmException(
        'Could not reach Ollama at localhost:11434. Is `ollama serve` running?',
      );
    }
    if (resp.statusCode != 200) {
      throw LlmException('Ollama error ${resp.statusCode}: ${_truncate(resp.body)}\n'
          'Is the model pulled?  ollama pull $m');
    }
    final out = (jsonDecode(resp.body)['response'] as String?)?.trim() ?? '';
    if (out.isEmpty) throw const LlmException('Ollama returned an empty response.');
    return out;
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

  /// Gemini advertises a far larger window; this is a deliberate cap so one
  /// request never becomes enormous and slow.
  @override
  int get contextTokens => 120000;

  @override
  Future<String> summarise(
    String text, {
    String? model,
    String? apiKey,
    AiMode mode = AiMode.summary,
    SummaryLength length = SummaryLength.standard,
    String? promptOverride,
  }) async {
    if (apiKey == null || apiKey.isEmpty) {
      throw const LlmException('Gemini needs an API key. Add one in Settings.');
    }
    final m = model ?? defaultModel;
    final http.Response resp;
    try {
      resp = await http.post(
        Uri.parse(
            'https://generativelanguage.googleapis.com/v1beta/models/$m:generateContent'),
        headers: {'Content-Type': 'application/json', 'x-goog-api-key': apiKey},
        body: jsonEncode({
          'contents': [
            {
              'parts': [
                {
                  'text': buildPrompt(text,
                      mode: mode,
                      length: length,
                      promptOverride: promptOverride)
                }
              ]
            }
          ],
          'generationConfig': {'temperature': 0.3},
        }),
      );
    } catch (e) {
      throw LlmException('Could not reach the Gemini API: $e');
    }
    if (resp.statusCode != 200) {
      throw LlmException('Gemini error ${resp.statusCode}: ${_truncate(resp.body)}');
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final candidates = data['candidates'] as List?;
    if (candidates == null || candidates.isEmpty) {
      // Usually a safety block — surface it rather than returning blank.
      throw LlmException('Gemini returned no candidates: ${_truncate(resp.body)}');
    }
    final parts = candidates.first['content']?['parts'] as List? ?? [];
    final out = parts.map((p) => p['text'] ?? '').join().trim();
    if (out.isEmpty) throw const LlmException('Gemini returned an empty response.');
    return out;
  }
}

/// Groq — open models (Llama, Qwen), free tier, very fast.
class GroqProvider extends LlmProvider {
  const GroqProvider();

  @override
  String get id => 'groq';
  @override
  String get name => 'Groq';
  @override
  String get defaultModel => 'llama-3.3-70b-versatile';
  @override
  List<String> get suggestedModels =>
      ['llama-3.3-70b-versatile', 'llama-3.1-8b-instant', 'qwen-2.5-32b'];
  @override
  bool get isCloud => true;
  @override
  String? get keyName => 'GROQ_API_KEY';
  @override
  String? get keyUrl => 'https://console.groq.com/keys';
  @override
  int get contextTokens => 32000;

  @override
  Future<String> summarise(
    String text, {
    String? model,
    String? apiKey,
    AiMode mode = AiMode.summary,
    SummaryLength length = SummaryLength.standard,
    String? promptOverride,
  }) =>
      openAiCompatible(
        baseUrl: 'https://api.groq.com/openai/v1',
        model: model ?? defaultModel,
        apiKey: apiKey ?? '',
        prompt: buildPrompt(text,
            mode: mode, length: length, promptOverride: promptOverride),
        providerName: name,
      );
}

/// OpenRouter — one key, hundreds of models, many open and free.
class OpenRouterProvider extends LlmProvider {
  const OpenRouterProvider();

  @override
  String get id => 'openrouter';
  @override
  String get name => 'OpenRouter';
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
  bool get isCloud => true;
  @override
  String? get keyName => 'OPENROUTER_API_KEY';
  @override
  String? get keyUrl => 'https://openrouter.ai/keys';

  /// Varies wildly by model, so this is the conservative floor.
  @override
  int get contextTokens => 32000;

  @override
  Future<String> summarise(
    String text, {
    String? model,
    String? apiKey,
    AiMode mode = AiMode.summary,
    SummaryLength length = SummaryLength.standard,
    String? promptOverride,
  }) =>
      openAiCompatible(
        baseUrl: 'https://openrouter.ai/api/v1',
        model: model ?? defaultModel,
        apiKey: apiKey ?? '',
        prompt: buildPrompt(text,
            mode: mode, length: length, promptOverride: promptOverride),
        providerName: name,
        extraHeaders: {'X-Title': 'audiobook-reader'},
      );
}

/// Together AI — open models, paid.
class TogetherProvider extends LlmProvider {
  const TogetherProvider();

  @override
  String get id => 'together';
  @override
  String get name => 'Together AI';
  @override
  String get defaultModel => 'meta-llama/Llama-3.3-70B-Instruct-Turbo';
  @override
  List<String> get suggestedModels => [
        'meta-llama/Llama-3.3-70B-Instruct-Turbo',
        'Qwen/Qwen2.5-72B-Instruct-Turbo',
        'deepseek-ai/DeepSeek-V3',
      ];
  @override
  bool get isCloud => true;
  @override
  String? get keyName => 'TOGETHER_API_KEY';
  @override
  String? get keyUrl => 'https://api.together.xyz/settings/api-keys';
  @override
  int get contextTokens => 32000;

  @override
  Future<String> summarise(
    String text, {
    String? model,
    String? apiKey,
    AiMode mode = AiMode.summary,
    SummaryLength length = SummaryLength.standard,
    String? promptOverride,
  }) =>
      openAiCompatible(
        baseUrl: 'https://api.together.xyz/v1',
        model: model ?? defaultModel,
        apiKey: apiKey ?? '',
        prompt: buildPrompt(text,
            mode: mode, length: length, promptOverride: promptOverride),
        providerName: name,
      );
}

/// Hugging Face router — open models, free tier is rate-limited.
class HuggingFaceProvider extends LlmProvider {
  const HuggingFaceProvider();

  @override
  String get id => 'huggingface';
  @override
  String get name => 'Hugging Face';
  @override
  String get defaultModel => 'meta-llama/Llama-3.1-8B-Instruct';
  @override
  List<String> get suggestedModels => [
        'meta-llama/Llama-3.1-8B-Instruct',
        'Qwen/Qwen2.5-7B-Instruct',
        'mistralai/Mistral-7B-Instruct-v0.3',
      ];
  @override
  bool get isCloud => true;
  @override
  String? get keyName => 'HF_TOKEN';
  @override
  String? get keyUrl => 'https://huggingface.co/settings/tokens';
  @override
  int get contextTokens => 16000;

  @override
  Future<String> summarise(
    String text, {
    String? model,
    String? apiKey,
    AiMode mode = AiMode.summary,
    SummaryLength length = SummaryLength.standard,
    String? promptOverride,
  }) =>
      openAiCompatible(
        baseUrl: 'https://router.huggingface.co/v1',
        model: model ?? defaultModel,
        apiKey: apiKey ?? '',
        prompt: buildPrompt(text,
            mode: mode, length: length, promptOverride: promptOverride),
        providerName: name,
      );
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

const kDefaultModels = {
  'ollama': 'qwen2.5:1.5b',
  'gemini': 'gemini-2.5-flash',
};

String? defaultModel(String provider) => providerById(provider).defaultModel;
