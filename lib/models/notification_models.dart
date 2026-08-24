/// Classification of system and account notification events.
enum NotificationType {
  // File and NeoSync lifecycle events.
  fileUploadCompleted,
  fileDownloadRequested,
  fileDeleted,
  quotaExceeded,

  // Authentication and user profile events.
  userRegistered,
  userLoggedIn,
  emailVerified,
  passwordReset,
  planUpdated,
  quotaUpdated,

  // Subscription and payment events.
  planChanged,
  paymentSucceeded,
  paymentFailed,
  subscriptionCreated,
  subscriptionUpdated,
  subscriptionCanceled,
  invoiceCreated,

  // Legacy event types preserved for backward compatibility.
  planUpgraded,
  userCreated,

  unknown,
}

/// Represents a notification message delivered to the user via the API or WebSocket.
class NotificationMessage {
  /// Unique identifier for the notification.
  final String id;

  /// The unique ID of the user who received the notification.
  final String userId;

  /// The category of the event that triggered this notification.
  final NotificationType eventType;

  /// Human-readable message text.
  final String message;

  /// Additional contextual metadata associated with the event.
  final Map<String, dynamic> data;

  /// Timestamp indicating when the notification was generated.
  final DateTime receivedAt;

  /// Whether the user has marked this notification as read.
  final bool isRead;

  NotificationMessage({
    required this.id,
    required this.userId,
    required this.eventType,
    required this.message,
    required this.data,
    required this.receivedAt,
    this.isRead = false,
  });

  /// Creates a [NotificationMessage] from a JSON-compatible map.
  factory NotificationMessage.fromJson(Map<String, dynamic> json) {
    return NotificationMessage(
      id: (json['id'] ?? '').toString(),
      userId: (json['user_id'] ?? '').toString(),
      eventType: _parseEventType((json['event_type'] ?? '').toString()),
      message: (json['message'] ?? '').toString(),
      data: json['data'] is Map ? Map<String, dynamic>.from(json['data']) : {},
      receivedAt:
          DateTime.tryParse((json['received_at'] ?? '').toString()) ??
          DateTime.now(),
      isRead: (json['is_read'] ?? false).toString().toLowerCase() == 'true',
    );
  }

  /// Converts the notification instance into a JSON-compatible map.
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'user_id': userId,
      'event_type': eventType.toString().split('.').last,
      'message': message,
      'data': data,
      'received_at': receivedAt.toIso8601String(),
      'is_read': isRead,
    };
  }

  /// Internal helper to map string-based API event types to the [NotificationType] enum.
  static NotificationType _parseEventType(String eventType) {
    switch (eventType) {
      // File/NeoSync events
      case 'file.upload.completed':
      case 'upload.completed':
        return NotificationType.fileUploadCompleted;
      case 'file.download.requested':
      case 'download.completed':
        return NotificationType.fileDownloadRequested;
      case 'file.deleted':
        return NotificationType.fileDeleted;
      case 'quota.exceeded':
        return NotificationType.quotaExceeded;

      // Auth events
      case 'user.registered':
        return NotificationType.userRegistered;
      case 'user.logged_in':
        return NotificationType.userLoggedIn;
      case 'user.email.verified':
      case 'email.verified':
        return NotificationType.emailVerified;
      case 'user.password.reset':
      case 'password.reset':
        return NotificationType.passwordReset;
      case 'user.plan.updated':
      case 'plan.updated':
        return NotificationType.planUpdated;
      case 'user.quota.updated':
      case 'quota.updated':
        return NotificationType.quotaUpdated;

      // Billing events
      case 'plan.changed':
        return NotificationType.planChanged;
      case 'payment.succeeded':
        return NotificationType.paymentSucceeded;
      case 'payment.failed':
        return NotificationType.paymentFailed;
      case 'subscription.created':
        return NotificationType.subscriptionCreated;
      case 'subscription.updated':
        return NotificationType.subscriptionUpdated;
      case 'subscription.deleted':
      case 'subscription.canceled':
        return NotificationType.subscriptionCanceled;
      case 'invoice.created':
        return NotificationType.invoiceCreated;

      // Legacy/compatibility
      case 'plan.upgraded':
        return NotificationType.planUpgraded;
      case 'user.created':
        return NotificationType.userCreated;

      default:
        return NotificationType.unknown;
    }
  }

  /// Returns a user-friendly display name for the notification category.
  String get eventTypeDisplayName {
    switch (eventType) {
      case NotificationType.fileUploadCompleted:
        return 'File Upload';
      case NotificationType.fileDownloadRequested:
        return 'File Download';
      case NotificationType.fileDeleted:
        return 'File Deleted';
      case NotificationType.quotaExceeded:
        return 'Quota Exceeded';
      case NotificationType.userRegistered:
        return 'Welcome!';
      case NotificationType.userLoggedIn:
        return 'Login Success';
      case NotificationType.emailVerified:
        return 'Email Verified';
      case NotificationType.passwordReset:
        return 'Password Reset';
      case NotificationType.planUpdated:
        return 'Plan Updated';
      case NotificationType.quotaUpdated:
        return 'Quota Updated';
      case NotificationType.planChanged:
        return 'Plan Changed';
      case NotificationType.paymentSucceeded:
        return 'Payment Success';
      case NotificationType.paymentFailed:
        return 'Payment Failed';
      case NotificationType.subscriptionCreated:
        return 'Subscription Active';
      case NotificationType.subscriptionUpdated:
        return 'Subscription Updated';
      case NotificationType.subscriptionCanceled:
        return 'Subscription Canceled';
      case NotificationType.invoiceCreated:
        return 'Invoice Created';
      case NotificationType.planUpgraded:
        return 'Plan Upgraded';
      case NotificationType.userCreated:
        return 'Account Created';
      default:
        return 'Notification';
    }
  }

  /// Returns a localized "time ago" string relative to the current time.
  String get timeAgo {
    final now = DateTime.now();
    final difference = now.difference(receivedAt);

    if (difference.inDays > 0) {
      return '${difference.inDays}d ago';
    } else if (difference.inHours > 0) {
      return '${difference.inHours}h ago';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes}m ago';
    } else {
      return 'Just now';
    }
  }
}

/// Represents a message received via the real-time WebSocket connection.
class WebSocketMessage {
  /// The type of message (e.g., 'notification', 'ping', 'missed_notifications').
  final String type;

  /// The raw data payload of the message.
  final Map<String, dynamic> data;

  /// Timestamp indicating when the message was received or generated.
  final DateTime timestamp;

  WebSocketMessage({
    required this.type,
    required this.data,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  /// Creates a [WebSocketMessage] from a JSON-compatible map.
  factory WebSocketMessage.fromJson(Map<String, dynamic> json) {
    return WebSocketMessage(
      type: (json['type'] ?? '').toString(),
      data: json['data'] is Map ? Map<String, dynamic>.from(json['data']) : {},
      timestamp:
          DateTime.tryParse((json['timestamp'] ?? '').toString()) ??
          DateTime.now(),
    );
  }

  /// Converts the message into a JSON-compatible map.
  Map<String, dynamic> toJson() {
    return {
      'type': type,
      'data': data,
      'timestamp': timestamp.toIso8601String(),
    };
  }

  bool get isNotification => type == 'notification';
  bool get isPing => type == 'ping';
  bool get isPong => type == 'pong';
  bool get isMissedNotifications => type == 'missed_notifications';

  /// Attempts to parse the message data as a [NotificationMessage].
  ///
  /// Returns null if the message type is not a notification or if parsing fails.
  NotificationMessage? get asNotification {
    if (!isNotification) return null;

    Map<String, dynamic> notificationData;
    if (data['type'] == 'notification' && data['data'] != null) {
      // Wrapper format used in some API versions.
      notificationData = data['data'];
    } else if (data.containsKey('event_type')) {
      // Direct notification structure.
      notificationData = data;
    } else {
      return null;
    }

    return NotificationMessage.fromJson(notificationData);
  }
}
