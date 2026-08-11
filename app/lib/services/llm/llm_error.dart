/// Typed failures from the LLM layer.
///
/// A plain string message forces the caller to guess whether a failure is worth
/// retrying. "429 Too Many Requests" and "401 Invalid API key" both used to
/// arrive as text, so the executor could either retry everything (hammering a
/// provider that will never accept the key) or retry nothing (giving up on a
/// blip that would have cleared in two seconds). The distinction below is the
/// whole point.
sealed class LlmError implements Exception {
  const LlmError(this.message, {this.provider});

  final String message;
  final String? provider;

  /// Whether retrying the identical request could plausibly succeed.
  bool get isRetryable;

  /// Suggested wait before the next attempt, when the provider tells us.
  Duration? get retryAfter => null;

  @override
  String toString() => provider == null ? message : '$provider: $message';
}

/// Rate limited — retry after a delay. The one failure that is *expected* under
/// normal use of a free tier.
class RateLimited extends LlmError {
  const RateLimited(super.message, {super.provider, this.after});

  final Duration? after;

  @override
  bool get isRetryable => true;
  @override
  Duration? get retryAfter => after;
}

/// The provider is up but broke (5xx). Usually transient.
class ProviderUnavailable extends LlmError {
  const ProviderUnavailable(super.message, {super.provider});
  @override
  bool get isRetryable => true;
}

/// Network-level failure: DNS, connection reset, timeout.
class TransportFailure extends LlmError {
  const TransportFailure(super.message, {super.provider});
  @override
  bool get isRetryable => true;
}

/// Missing, malformed or rejected credentials. Retrying cannot help — the user
/// has to fix the key.
class AuthFailed extends LlmError {
  const AuthFailed(super.message, {super.provider});
  @override
  bool get isRetryable => false;
}

/// The request exceeded the model's context. Retrying the same payload is
/// pointless; the caller must chunk more aggressively.
class ContextExceeded extends LlmError {
  const ContextExceeded(super.message, {super.provider});
  @override
  bool get isRetryable => false;
}

/// Model name wrong, not pulled, or not available on this account.
class ModelUnavailable extends LlmError {
  const ModelUnavailable(super.message, {super.provider});
  @override
  bool get isRetryable => false;
}

/// The request was fine but the response was empty or blocked (e.g. safety).
class EmptyResponse extends LlmError {
  const EmptyResponse(super.message, {super.provider});
  @override
  bool get isRetryable => false;
}

/// Caller error — nothing to summarise, unknown provider.
class InvalidRequest extends LlmError {
  const InvalidRequest(super.message, {super.provider});
  @override
  bool get isRetryable => false;
}

/// The user cancelled. Not really an error, but it travels the same path.
class Cancelled extends LlmError {
  const Cancelled([super.message = 'Cancelled.']);
  @override
  bool get isRetryable => false;
}

/// Maps an HTTP status to the right error type.
LlmError errorForStatus(int status, String body, String provider) {
  final snippet = body.length > 300 ? '${body.substring(0, 300)}…' : body;
  return switch (status) {
    401 || 403 => AuthFailed('API key rejected. Check it in Settings.',
        provider: provider),
    404 => ModelUnavailable('Model not found: $snippet', provider: provider),
    413 => ContextExceeded('Request too large: $snippet', provider: provider),
    429 => RateLimited('Rate limited.', provider: provider),
    >= 500 && < 600 =>
      ProviderUnavailable('Server error $status: $snippet', provider: provider),
    _ when _looksLikeContextError(body) =>
      ContextExceeded('Context window exceeded: $snippet', provider: provider),
    _ => ProviderUnavailable('Error $status: $snippet', provider: provider),
  };
}

bool _looksLikeContextError(String body) {
  final b = body.toLowerCase();
  return b.contains('context length') ||
      b.contains('context_length') ||
      b.contains('too many tokens') ||
      b.contains('maximum context');
}

/// Cooperative cancellation.
///
/// Dart has no ambient cancellation, so long pipelines have to check between
/// stages. Closing the summary sheet cancels the token, and the executor stops
/// before starting the next chunk instead of finishing work nobody will see —
/// which on a cloud provider is money.
class CancellationToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;

  /// Throws if cancellation has been requested.
  void throwIfCancelled() {
    if (_cancelled) throw const Cancelled();
  }
}
