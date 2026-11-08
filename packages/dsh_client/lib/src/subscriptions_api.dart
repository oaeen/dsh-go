/// Subscription sign-in (ChatGPT, Claude) through dsh-app's engine-side auth
/// bridge (`@dsh-app/auth`, service `appAuth`).
///
/// DSH 0.2.1 already carries both sign-in flows: the built-in `llm-pi-ai`
/// adapter registers one authorization flow per pi-ai provider that has a
/// login (`llm-pi-ai/openai-codex`, `llm-pi-ai/anthropic`) and stores the
/// grant in the local credential store. It does not expose "begin a sign-in"
/// to clients, so the bridge does that and turns the flow's interaction into
/// a small polled state machine:
///
/// ```
/// beginLogin → attemptId
/// pollLogin(attemptId) → starting → open | device | prompt → done | failed
///                                    (answerLogin for prompt)  cancelled
/// ```
///
/// Polling (not a stream) so it works the same over every carrier. Once an
/// attempt is `done`, the bridge has also declared the route
/// (`llm-pi-ai.providers.<id>`) so its models show up in the catalog;
/// [DshSubscriptions.signOut] removes both.
library;

import 'json.dart';
import 'session_api.dart';

/// Credential environment variable marker used by Magpie plugin routes in `llm-pi-ai`.
const String kMagpiePluginKeyEnv = 'DSH_MAGPIE_PLUGIN_TOKEN';

/// A subscription the bridge can sign in to (built-in ChatGPT/Claude or an
/// installed Magpie subscription plugin provider).
final class Subscription {
  const Subscription(this.wire, {this.displayName});

  static const Subscription chatgpt = Subscription('openai-codex', displayName: 'ChatGPT');
  static const Subscription claude = Subscription('anthropic', displayName: 'Claude');

  /// Built-in subscriptions always present in the bridge.
  static const List<Subscription> values = [chatgpt, claude];

  /// The pi-ai provider id (and `llm-pi-ai` route id).
  final String wire;

  /// Optional display name reported by a Magpie plugin.
  final String? displayName;

  bool get isBuiltIn => wire == chatgpt.wire || wire == claude.wire;

  static Subscription? fromWire(String? wire) {
    for (final s in values) {
      if (s.wire == wire) return s;
    }
    return null;
  }

  /// Resolves a built-in or Magpie plugin subscription from an `appAuth/list` entry.
  static Subscription? fromEntry(Map<String, Object?> map) {
    final id = asString(map['id']);
    if (id == null || id.isEmpty) return null;
    final builtIn = fromWire(id);
    if (builtIn != null) return builtIn;
    final displayName = asString(map['displayName']);
    final pluginSpec = asString(map['pluginSpec']);
    if (displayName != null || pluginSpec != null) {
      return Subscription(id, displayName: displayName);
    }
    return null;
  }

  @override
  bool operator ==(Object other) => other is Subscription && other.wire == wire;

  @override
  int get hashCode => wire.hashCode;

  @override
  String toString() => 'Subscription($wire)';
}

/// A boolean option declared by a Magpie subscription plugin.
class SubscriptionOption {
  const SubscriptionOption({
    required this.key,
    required this.label,
    this.labelEn,
    this.description,
    this.descriptionEn,
    this.confirm,
    this.confirmEn,
    this.filtersModels = false,
    required this.value,
  });

  factory SubscriptionOption.fromJson(Map<String, Object?> json) => SubscriptionOption(
    key: asString(json['key']) ?? '',
    label: asString(json['label']) ?? asString(json['key']) ?? '',
    labelEn: asString(json['labelEn']),
    description: asString(json['description']),
    descriptionEn: asString(json['descriptionEn']),
    confirm: asString(json['confirm']),
    confirmEn: asString(json['confirmEn']),
    filtersModels: json['filtersModels'] == true,
    value: json['value'] == true,
  );

  final String key;
  final String label;
  final String? labelEn;
  final String? description;
  final String? descriptionEn;
  final String? confirm;
  final String? confirmEn;
  final bool filtersModels;
  final bool value;
}

/// Sign-in state of one subscription.
class SubscriptionStatus {
  const SubscriptionStatus({
    required this.subscription,
    required this.signedIn,
    this.account,
    this.displayName,
    this.pluginSpec,
    this.supportsUsage = false,
    this.supportsCheckin = false,
    this.options = const [],
  });

  factory SubscriptionStatus.fromJson(Subscription subscription, Map<String, Object?> json) => SubscriptionStatus(
    subscription: subscription,
    signedIn: json['signedIn'] == true,
    account: asString(json['account']),
    displayName: asString(json['displayName']) ?? subscription.displayName,
    pluginSpec: asString(json['pluginSpec']),
    supportsUsage: json['supportsUsage'] == true,
    supportsCheckin: json['supportsCheckin'] == true,
    options: [
      for (final item in asListOrEmpty(json['options']))
        if (asMap(item) case final m?)
          if ((asString(m['key']) ?? '').isNotEmpty) SubscriptionOption.fromJson(m),
    ],
  );

  final Subscription subscription;
  final bool signedIn;

  /// Who is signed in (an email or plan name), when the grant says.
  final String? account;

  /// Display name reported by the plugin, if any.
  final String? displayName;

  /// Plugin package/spec that provides this subscription, or null for built-ins.
  final String? pluginSpec;

  /// Whether this subscription supports querying usage/quota (`appAuth/usage`).
  final bool supportsUsage;

  /// Whether this subscription supports daily check-in (`appAuth/checkin`).
  final bool supportsCheckin;

  /// Configurable boolean options declared by the plugin.
  final List<SubscriptionOption> options;
}

/// Where a sign-in attempt is.
enum LoginPhase {
  /// The bridge is starting the flow.
  starting,

  /// Open [LoginStep.url] in a browser; the engine catches the callback.
  open,

  /// Show [LoginStep.userCode]; the person enters it at [LoginStep.url].
  device,

  /// The flow asks for text or option selection:
  /// [LoginStep.message], answered with [DshSubscriptions.answerLogin].
  prompt,
  done,
  failed,
  cancelled;

  static LoginPhase fromWire(String? wire) {
    for (final p in values) {
      if (p.name == wire) return p;
    }
    return LoginPhase.failed;
  }

  bool get finished => this == done || this == failed || this == cancelled;
}

/// A selectable option during a [LoginPhase.prompt] step.
class LoginPromptOption {
  const LoginPromptOption({required this.id, required this.label, this.hint});

  factory LoginPromptOption.fromJson(Map<String, Object?> json) => LoginPromptOption(
    id: asString(json['id']) ?? '',
    label: asString(json['label']) ?? asString(json['id']) ?? '',
    hint: asString(json['hint']),
  );

  final String id;
  final String label;
  final String? hint;
}

/// One poll of a sign-in attempt.
class LoginStep {
  const LoginStep({
    required this.phase,
    this.url,
    this.userCode,
    this.message,
    this.placeholder,
    this.options = const [],
    this.error,
  });

  factory LoginStep.fromJson(Map<String, Object?> json) => LoginStep(
    phase: LoginPhase.fromWire(asString(json['phase'])),
    url: asString(json['url']),
    userCode: asString(json['userCode']),
    message: asString(json['message']),
    placeholder: asString(json['placeholder']),
    options: [
      for (final item in asListOrEmpty(json['options']))
        if (asMap(item) case final m?)
          if ((asString(m['id']) ?? '').isNotEmpty) LoginPromptOption.fromJson(m),
    ],
    error: asString(json['error']),
  );

  final LoginPhase phase;
  final String? url;
  final String? userCode;
  final String? message;
  final String? placeholder;
  final List<LoginPromptOption> options;
  final String? error;
}

/// One quota/usage window returned by `appAuth/usage`.
class SubscriptionUsageWindow {
  const SubscriptionUsageWindow({
    required this.name,
    this.usedPercent,
    this.amount = 0,
    this.limit = 0,
    this.unit,
    this.display,
    this.resetsAt,
  });

  factory SubscriptionUsageWindow.fromJson(Map<String, Object?> json) => SubscriptionUsageWindow(
    name: asString(json['name']) ?? asString(json['label']) ?? '',
    usedPercent: switch (json['used']) {
      final num n => n.toDouble(),
      _ => null,
    },
    amount: switch (json['amount']) {
      final num n => n.toDouble(),
      _ => 0,
    },
    limit: switch (json['limit']) {
      final num n => n.toDouble(),
      _ => 0,
    },
    unit: asString(json['unit']),
    display: asString(json['display']),
    resetsAt: asString(json['resetsAt']),
  );

  final String name;
  final double? usedPercent;
  final double amount;
  final double limit;
  final String? unit;
  final String? display;
  final String? resetsAt;
}

/// Plan and usage windows returned by `appAuth/usage`.
class SubscriptionUsage {
  const SubscriptionUsage({
    this.plan,
    this.balance,
    this.currency,
    this.windows = const [],
  });

  factory SubscriptionUsage.fromJson(Map<String, Object?> json) => SubscriptionUsage(
    plan: asString(json['plan']),
    balance: switch (json['balance']) {
      final num n => n.toDouble(),
      _ => null,
    },
    currency: asString(json['currency']),
    windows: [
      for (final item in asListOrEmpty(json['windows']))
        if (asMap(item) case final m?) SubscriptionUsageWindow.fromJson(m),
    ],
  );

  final String? plan;
  final double? balance;
  final String? currency;
  final List<SubscriptionUsageWindow> windows;
}

/// Result of a daily check-in (`appAuth/checkin`).
class SubscriptionCheckin {
  const SubscriptionCheckin({
    required this.ok,
    required this.outcome,
    this.credit = 0,
    this.streak = 0,
    this.message,
  });

  factory SubscriptionCheckin.fromJson(Map<String, Object?> json) => SubscriptionCheckin(
    ok: json['ok'] == true || json['outcome'] == 'claimed' || json['outcome'] == 'done',
    outcome: asString(json['outcome']) ?? (json['ok'] == true ? 'claimed' : 'failed'),
    credit: switch (json['credit']) {
      final num n => n.toDouble(),
      _ => 0,
    },
    streak: asInt(json['streak']) ?? 0,
    message: asString(json['message']),
  );

  final bool ok;
  final String outcome;
  final double credit;
  final int streak;
  final String? message;
}

/// One entry in the Magpie subscription plugin marketplace (`appAuth/market`).
class SubscriptionMarketPlugin {
  const SubscriptionMarketPlugin({
    required this.package,
    required this.name,
    this.icon,
    this.providers = const [],
    this.community = false,
    this.summaryZh = '',
    this.summaryEn = '',
    this.installed = false,
    this.version,
    this.error,
  });

  factory SubscriptionMarketPlugin.fromJson(Map<String, Object?> json) => SubscriptionMarketPlugin(
    package: asString(json['package']) ?? '',
    name: asString(json['name']) ?? asString(json['package']) ?? '',
    icon: asString(json['icon']),
    providers: [
      for (final item in asListOrEmpty(json['providers']))
        if (asString(item) case final s? when s.isNotEmpty) s,
    ],
    community: json['community'] == true,
    summaryZh: asString(json['summaryZh']) ?? '',
    summaryEn: asString(json['summaryEn']) ?? '',
    installed: json['installed'] == true,
    version: asString(json['version']),
    error: asString(json['error']),
  );

  final String package;
  final String name;
  final String? icon;
  final List<String> providers;
  final bool community;
  final String summaryZh;
  final String summaryEn;
  final bool installed;
  final String? version;
  final String? error;
}

/// Result of installing a Magpie subscription plugin (`appAuth/installPlugin`).
class SubscriptionPluginInstallResult {
  const SubscriptionPluginInstallResult({
    required this.spec,
    required this.package,
    this.version,
    this.providers = const [],
  });

  factory SubscriptionPluginInstallResult.fromJson(Map<String, Object?> json) => SubscriptionPluginInstallResult(
    spec: asString(json['spec']) ?? '',
    package: asString(json['package']) ?? '',
    version: asString(json['version']),
    providers: [
      for (final item in asListOrEmpty(json['providers']))
        if (asString(item) case final s? when s.isNotEmpty) s,
    ],
  );

  final String spec;
  final String package;
  final String? version;
  final List<String> providers;
}

extension DshSubscriptions on DshClient {
  /// `appAuth/list`: every subscription the bridge knows, signed in or not.
  /// Throws `remote/unknown-method` (or similar) when the bridge is absent.
  Future<List<SubscriptionStatus>> subscriptions() async {
    final result = asMap(await rpc.call('appAuth/list')) ?? const {};
    return [
      for (final entry in asListOrEmpty(result['providers']))
        if (asMap(entry) case final map?)
          if (Subscription.fromEntry(map) case final s?) SubscriptionStatus.fromJson(s, map),
    ];
  }

  /// `appAuth/begin`: starts a sign-in; returns the attempt id to poll.
  Future<String> beginLogin(Subscription subscription) async {
    final result = asMap(await rpc.call('appAuth/begin', {'provider': subscription.wire})) ?? const {};
    final id = asString(result['attemptId']);
    if (id == null) throw const FormatException('appAuth/begin: no attemptId');
    return id;
  }

  /// `appAuth/poll`: the attempt's current step.
  Future<LoginStep> pollLogin(String attemptId) async =>
      LoginStep.fromJson(asMap(await rpc.call('appAuth/poll', {'attemptId': attemptId})) ?? const {});

  /// `appAuth/answer`: replies to a [LoginPhase.prompt].
  Future<void> answerLogin(String attemptId, String value) =>
      rpc.call('appAuth/answer', {'attemptId': attemptId, 'value': value});

  /// `appAuth/cancel`: abandons an attempt (no-op once finished).
  Future<void> cancelLogin(String attemptId) => rpc.call('appAuth/cancel', {'attemptId': attemptId});

  /// `appAuth/signOut`: deletes the grant and the route.
  Future<void> signOut(Subscription subscription) => rpc.call('appAuth/signOut', {'provider': subscription.wire});

  /// `appAuth/usage`: queries subscription plan and quota windows.
  Future<SubscriptionUsage> subscriptionUsage(Subscription subscription) async =>
      SubscriptionUsage.fromJson(asMap(await rpc.call('appAuth/usage', {'provider': subscription.wire})) ?? const {});

  /// `appAuth/checkin`: performs daily check-in for a plugin subscription.
  Future<SubscriptionCheckin> subscriptionCheckin(Subscription subscription) async => SubscriptionCheckin.fromJson(
    asMap(await rpc.call('appAuth/checkin', {'provider': subscription.wire})) ?? const {},
  );

  /// `appAuth/setOption`: updates a boolean option on a plugin subscription.
  Future<List<SubscriptionOption>> setSubscriptionOption(
    Subscription subscription,
    String key,
    bool value,
  ) async {
    final result = asMap(
          await rpc.call('appAuth/setOption', {
            'provider': subscription.wire,
            'key': key,
            'value': value,
          }),
        ) ??
        const {};
    return [
      for (final item in asListOrEmpty(result['options']))
        if (asMap(item) case final m?)
          if ((asString(m['key']) ?? '').isNotEmpty) SubscriptionOption.fromJson(m),
    ];
  }

  /// `appAuth/market`: lists Magpie subscription plugins from the marketplace.
  Future<List<SubscriptionMarketPlugin>> subscriptionMarket() async {
    final result = asMap(await rpc.call('appAuth/market')) ?? const {};
    return [
      for (final item in asListOrEmpty(result['plugins']))
        if (asMap(item) case final m?)
          if ((asString(m['package']) ?? '').isNotEmpty) SubscriptionMarketPlugin.fromJson(m),
    ];
  }

  /// `appAuth/installPlugin`: installs and activates a Magpie subscription plugin.
  Future<SubscriptionPluginInstallResult> installSubscriptionPlugin(String spec) async {
    final result = asMap(await rpc.call('appAuth/installPlugin', {'spec': spec}, const Duration(minutes: 2))) ??
        const {};
    return SubscriptionPluginInstallResult.fromJson(result);
  }

  /// `appAuth/removePlugin`: uninstalls a Magpie subscription plugin.
  Future<List<String>> removeSubscriptionPlugin(String spec) async {
    final result = asMap(await rpc.call('appAuth/removePlugin', {'spec': spec}, const Duration(minutes: 1))) ??
        const {};
    return [
      for (final item in asListOrEmpty(result['removedProviders']))
        if (asString(item) case final s? when s.isNotEmpty) s,
    ];
  }
}
