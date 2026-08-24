class AppConfig {
  /// Base URL for the NeoSync authentication service.
  static const String authBaseUrl = 'https://auth.neosync.cloud';

  /// Base URL for the NeoSync v2 cloud synchronization service.
  static const String neoSyncBaseUrl = 'https://sync.neosync.cloud';

  /// Historical NeoSync v1 endpoint. Read/migration compatibility only.
  static const String legacyNeoSyncBaseUrl = 'https://neosync.neogamelab.com';

  /// Base URL for the billing and subscription management service.
  static const String billingBaseUrl = 'https://billing.neosync.cloud';

  /// WebSocket endpoint for the real-time notification service.
  static const String notifyBaseUrl = 'ws://notify.neosync.cloud/ws';
}
