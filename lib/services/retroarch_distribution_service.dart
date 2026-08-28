import 'package:shared_preferences/shared_preferences.dart';

enum RetroArchDistribution { testFlight, appStore }

class RetroArchDistributionService {
  RetroArchDistributionService._();

  static const _key = 'retroarch_ios_distribution_v1';

  /// Existing NeoStation users historically used the TestFlight integration,
  /// therefore TestFlight is the safe default until the user explicitly links
  /// an App Store RetroArch folder.
  static Future<RetroArchDistribution> current() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key) == 'appstore'
        ? RetroArchDistribution.appStore
        : RetroArchDistribution.testFlight;
  }

  static Future<void> set(RetroArchDistribution value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      value == RetroArchDistribution.appStore ? 'appstore' : 'testflight',
    );
  }

  static Future<void> useTestFlight() => set(RetroArchDistribution.testFlight);
  static Future<void> useAppStore() => set(RetroArchDistribution.appStore);
}
