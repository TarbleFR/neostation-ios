/// Represents an authenticated NeoStation user account.
///
/// Contains profile information, cloud storage quotas, and Stripe-based
/// subscription status for the NeoSync service.
class User {
  /// Unique identifier for the user account.
  final String id;

  /// Display name or handle of the user.
  final String username;

  /// Registered email address.
  final String email;

  /// Current subscription plan level (e.g., 'free', 'silver', 'gold').
  final String plan;

  /// Total storage capacity allocated for cloud saves in bytes.
  final int storageQuotaBytes;

  /// Current amount of storage used by the user's cloud saves in bytes.
  final int storageUsedBytes;

  /// Whether the user's email address has been verified.
  final bool emailVerified;

  /// Timestamp when the account was first created.
  final DateTime createdAt;

  /// Timestamp of the last profile update.
  final DateTime updatedAt;

  /// Unique identifier for the associated Stripe customer.
  final String? stripeCustomerId;

  /// Unique identifier for the active Stripe subscription.
  final String? stripeSubscriptionId;

  /// Current status of the Stripe subscription (e.g., 'active', 'past_due').
  final String? stripeSubscriptionStatus;

  /// Date when the current subscription period ends.
  final DateTime? subscriptionEndDate;

  User({
    required this.id,
    required this.username,
    required this.email,
    required this.plan,
    required this.storageQuotaBytes,
    required this.storageUsedBytes,
    required this.emailVerified,
    required this.createdAt,
    required this.updatedAt,
    this.stripeCustomerId,
    this.stripeSubscriptionId,
    this.stripeSubscriptionStatus,
    this.subscriptionEndDate,
  });

  /// Creates a [User] instance from a JSON-compatible map provided by the API.
  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: (json['id'] ?? '').toString(),
      username: (json['username'] ?? '').toString(),
      email: (json['email'] ?? '').toString(),
      plan: (json['plan'] ?? 'bronze').toString(),
      storageQuotaBytes:
          int.tryParse((json['storage_quota_bytes'] ?? '0').toString()) ?? 0,
      storageUsedBytes:
          int.tryParse((json['storage_used_bytes'] ?? '0').toString()) ?? 0,
      emailVerified:
          (json['email_verified'] ?? false).toString().toLowerCase() == 'true',
      createdAt:
          DateTime.tryParse((json['created_at'] ?? '').toString()) ??
          DateTime.now(),
      updatedAt:
          DateTime.tryParse((json['updated_at'] ?? '').toString()) ??
          DateTime.now(),
      stripeCustomerId: json['stripe_customer_id']?.toString(),
      stripeSubscriptionId: json['stripe_subscription_id']?.toString(),
      stripeSubscriptionStatus: json['stripe_subscription_status']?.toString(),
      subscriptionEndDate: json['subscription_end_date'] != null
          ? DateTime.tryParse(json['subscription_end_date'].toString())
          : null,
    );
  }

  /// Converts the user instance into a JSON-compatible map.
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'username': username,
      'email': email,
      'plan': plan,
      'storage_quota_bytes': storageQuotaBytes,
      'storage_used_bytes': storageUsedBytes,
      'email_verified': emailVerified,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'stripe_customer_id': stripeCustomerId,
      'stripe_subscription_id': stripeSubscriptionId,
      'stripe_subscription_status': stripeSubscriptionStatus,
      'subscription_end_date': subscriptionEndDate?.toIso8601String(),
    };
  }

  /// Returns the amount of used storage formatted as a localized string.
  String get storageUsedFormatted {
    return _formatBytes(storageUsedBytes);
  }

  /// Returns the total storage quota formatted as a localized string.
  String get storageQuotaFormatted {
    return _formatBytes(storageQuotaBytes);
  }

  /// Returns the amount of remaining storage space formatted as a localized string.
  String get storageRemainingFormatted {
    final remaining = storageQuotaBytes - storageUsedBytes;
    return _formatBytes(remaining > 0 ? remaining : 0);
  }

  /// Returns the percentage of the storage quota that has been consumed.
  double get storageUsagePercentage {
    if (storageQuotaBytes == 0) return 0.0;
    return (storageUsedBytes / storageQuotaBytes) * 100;
  }

  /// Whether the user currently has an active and valid subscription.
  bool get hasActiveSubscription {
    return subscriptionEndDate != null &&
        subscriptionEndDate!.isAfter(DateTime.now()) &&
        stripeSubscriptionStatus == 'active';
  }

  /// Returns a human-readable string indicating when the current subscription will expire.
  String get subscriptionEndDateFormatted {
    if (subscriptionEndDate == null) return 'N/A';

    final now = DateTime.now();
    final difference = subscriptionEndDate!.difference(now);

    if (difference.inDays > 30) {
      const months = [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec',
      ];
      return '${months[subscriptionEndDate!.month - 1]} ${subscriptionEndDate!.day}, ${subscriptionEndDate!.year}';
    } else if (difference.inDays > 1) {
      return 'in ${difference.inDays} days';
    } else if (difference.inDays == 1) {
      return 'tomorrow';
    } else if (difference.inHours > 1) {
      return 'in ${difference.inHours} hours';
    } else if (difference.inHours >= 0) {
      return 'today';
    } else {
      return 'Expired';
    }
  }

  /// Internal helper for formatting byte counts into human-readable units.
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
