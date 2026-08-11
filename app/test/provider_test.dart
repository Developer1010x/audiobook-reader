import 'dart:io' show Platform;

import 'package:audiobook_reader/services/llm/ai_mode.dart';
import 'package:audiobook_reader/services/llm/llm_provider.dart';
import 'package:audiobook_reader/services/llm/summary_length.dart';
import 'package:flutter_test/flutter_test.dart';

/// Contract tests over the provider registry. No network is touched — anything
/// that would make a request is asserted to fail *before* it does.
void main() {
  group('registry', () {
    test('ollama is first, so the private option is the default', () {
      expect(kProviders.first.id, 'ollama');
      expect(kProviders.first.isCloud, isFalse);
    });

    test('all six providers are registered with unique ids', () {
      final ids = kProviders.map((p) => p.id).toList();
      expect(ids, hasLength(6));
      expect(ids.toSet(), hasLength(6));
      expect(ids, containsAll(
          ['ollama', 'gemini', 'groq', 'openrouter', 'together', 'huggingface']));
    });

    test('unknown id falls back to the local provider, never to a cloud one', () {
      // A corrupt or stale setting must not silently start sending text to an API.
      expect(providerById('nonsense').isCloud, isFalse);
      expect(providerById('').id, 'ollama');
    });

    test('every provider declares a default model and suggestions', () {
      for (final p in kProviders) {
        expect(p.defaultModel, isNotEmpty, reason: p.id);
        expect(p.suggestedModels, isNotEmpty, reason: p.id);
        expect(p.suggestedModels, contains(p.defaultModel), reason: p.id);
      }
    });
  });

  group('cloud/local classification drives the UI warning', () {
    test('only ollama is local; every other provider is cloud', () {
      for (final p in kProviders) {
        expect(p.isCloud, p.id != 'ollama', reason: p.id);
      }
    });

    test('every cloud provider declares a key name and a place to get one', () {
      for (final p in kProviders.where((p) => p.isCloud)) {
        expect(p.keyName, isNotNull, reason: p.id);
        expect(p.keyName, isNotEmpty, reason: p.id);
        expect(p.keyUrl, isNotNull, reason: p.id);
      }
    });

    test('the local provider needs no key', () {
      expect(const OllamaProvider().keyName, isNull);
    });
  });

  group('keys are required before any request', () {
    for (final p in kProviders.where((p) => p.isCloud)) {
      test('${p.id} throws without a key rather than calling out', () async {
        await expectLater(
          p.summarise('some book text', apiKey: null),
          throwsA(isA<LlmException>()),
        );
        await expectLater(
          p.summarise('some book text', apiKey: ''),
          throwsA(isA<LlmException>()),
        );
      });
    }
  });

  group('platform availability', () {
    test('ollama is unavailable where there is no localhost daemon', () {
      final ollama = const OllamaProvider();
      final isDesktop = Platform.isLinux || Platform.isMacOS || Platform.isWindows;
      expect(ollama.isAvailableOnThisPlatform, isDesktop);
    });

    test('cloud providers are available everywhere', () {
      for (final p in kProviders.where((p) => p.isCloud)) {
        expect(p.isAvailableOnThisPlatform, isTrue, reason: p.id);
      }
    });
  });

  group('prompt', () {
    test('carries the text, the mode and the length constraint', () {
      final prompt = buildPrompt(
        'THE PASSAGE',
        mode: AiMode.summary,
        length: SummaryLength.brief,
      );
      expect(prompt, contains('THE PASSAGE'));
      expect(prompt, contains(SummaryLength.brief.instruction));
      expect(prompt, isNot(contains('{n}')));
      expect(prompt, isNot(contains('{text}')));
    });

    test('one line drops the mode shape rather than fighting it', () {
      // "One-line flashcards" is incoherent; length must win.
      final prompt = buildPrompt(
        'THE PASSAGE',
        mode: AiMode.flashcards,
        length: SummaryLength.oneLine,
      );
      expect(prompt, contains('EXACTLY ONE sentence'));
      expect(prompt, isNot(contains('flashcards')));
    });

    test('a prompt override replaces the mode instruction entirely', () {
      final prompt = buildPrompt(
        'THE PASSAGE',
        mode: AiMode.interview,
        promptOverride: 'CUSTOM MAP INSTRUCTION',
      );
      expect(prompt, contains('CUSTOM MAP INSTRUCTION'));
      expect(prompt, isNot(contains('interview questions')));
    });
  });

  group('context budgets', () {
    test('every provider declares a positive context and input budget', () {
      for (final p in kProviders) {
        expect(p.contextTokens, greaterThan(0), reason: p.id);
        expect(p.inputCharBudget, greaterThan(0), reason: p.id);
        // Input must leave room for the prompt and the answer.
        expect(p.inputCharBudget, lessThan(p.contextTokens * 3.6), reason: p.id);
      }
    });

    test('ollama declares more than its own silent default of 2048', () {
      // The bug this guards: Ollama ignores the model's real window and uses a
      // small default unless num_ctx is sent, truncating long input silently.
      expect(const OllamaProvider().contextTokens, greaterThan(4096));
    });
  });
}
