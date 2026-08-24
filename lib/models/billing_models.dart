/// Represents a payment or subscription session initiated by the user.
class BillingSession {
  /// Unique identifier for the billing session.
  final String id;

  /// The external URL where the user can complete the payment.
  final String url;

  /// The unique ID of the user associated with this session.
  final String userId;

  /// The name of the subscription plan (e.g., 'Pro', 'Ultimate').
  final String planName;

  /// The billing frequency (e.g., 'monthly', 'yearly').
  final String billingPeriod;

  /// The monetary amount to be charged.
  final double amount;

  /// The currency code (e.g., 'USD', 'EUR').
  final String currency;

  /// Current status of the session (e.g., 'pending', 'completed', 'cancelled').
  final String status;

  /// Timestamp indicating when the session was created.
  final DateTime createdAt;

  /// Optional expiration timestamp for the session link.
  final DateTime? expiresAt;

  BillingSession({
    required this.id,
    required this.url,
    required this.userId,
    required this.planName,
    required this.billingPeriod,
    required this.amount,
    required this.currency,
    required this.status,
    required this.createdAt,
    this.expiresAt,
  });

  /// Creates a [BillingSession] from a JSON object.
  factory BillingSession.fromJson(Map<String, dynamic> json) {
    return BillingSession(
      id: (json['id'] ?? '').toString(),
      url: (json['url'] ?? '').toString(),
      userId: (json['user_id'] ?? '').toString(),
      planName: (json['plan_name'] ?? '').toString(),
      billingPeriod: (json['billing_period'] ?? '').toString(),
      amount: double.tryParse((json['amount'] ?? '0').toString()) ?? 0.0,
      currency: (json['currency'] ?? 'USD').toString(),
      status: (json['status'] ?? 'pending').toString(),
      createdAt:
          DateTime.tryParse((json['created_at'] ?? '').toString()) ??
          DateTime.now(),
      expiresAt: json['expires_at'] != null
          ? DateTime.tryParse(json['expires_at'].toString())
          : null,
    );
  }

  /// Converts the session instance into a JSON-compatible map.
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'url': url,
      'user_id': userId,
      'plan_name': planName,
      'billing_period': billingPeriod,
      'amount': amount,
      'currency': currency,
      'status': status,
      'created_at': createdAt.toIso8601String(),
      'expires_at': expiresAt?.toIso8601String(),
    };
  }

  /// Returns true if the session's expiration time has passed.
  bool get isExpired {
    if (expiresAt == null) return false;
    return DateTime.now().isAfter(expiresAt!);
  }

  /// Returns the amount formatted as a localized currency string.
  String get amountFormatted {
    return '\$${amount.toStringAsFixed(2)} $currency';
  }
}

/// Information about a subscription plan offered within the application.
class PlanInfo {
  /// Internal machine name of the plan.
  final String name;

  /// User-friendly display name of the plan.
  final String displayName;

  /// Short summary of what the plan includes.
  final String description;

  /// Storage limit for NeoSync cloud saves, in bytes.
  final int storageQuotaBytes;

  /// Monthly subscription price.
  final double priceMonthly;

  /// Yearly subscription price.
  final double priceYearly;

  /// List of feature highlights included in this plan.
  final List<String> features;

  PlanInfo({
    required this.name,
    required this.displayName,
    required this.description,
    required this.storageQuotaBytes,
    required this.priceMonthly,
    required this.priceYearly,
    required this.features,
  });

  /// Creates a [PlanInfo] from a JSON object.
  factory PlanInfo.fromJson(Map<String, dynamic> json) {
    return PlanInfo(
      name: (json['name'] ?? '').toString(),
      displayName: (json['display_name'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      storageQuotaBytes:
          int.tryParse((json['storage_quota_bytes'] ?? '0').toString()) ?? 0,
      priceMonthly:
          double.tryParse((json['price_monthly'] ?? '0').toString()) ?? 0.0,
      priceYearly:
          double.tryParse((json['price_yearly'] ?? '0').toString()) ?? 0.0,
      features:
          (json['features'] as List?)?.map((e) => e.toString()).toList() ?? [],
    );
  }

  /// Converts the plan instance into a JSON-compatible map.
  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'display_name': displayName,
      'description': description,
      'storage_quota_bytes': storageQuotaBytes,
      'price_monthly': priceMonthly,
      'price_yearly': priceYearly,
      'features': features,
    };
  }

  /// Returns a human-readable string of the storage quota (e.g., '5.0 GB').
  String get storageQuotaFormatted {
    return _formatBytes(storageQuotaBytes);
  }

  /// Returns the monthly price as a formatted string.
  String get priceMonthlyFormatted =>
      '\$${priceMonthly.toStringAsFixed(2)}/month';

  /// Returns the yearly price as a formatted string.
  String get priceYearlyFormatted => '\$${priceYearly.toStringAsFixed(2)}/year';

  /// Internal helper to format byte counts into human-readable units.
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
