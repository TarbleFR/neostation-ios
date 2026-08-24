import 'package:flutter/material.dart';
import '../screens/scraper_screen/new_scraper_options_screen.dart';
import '../screens/scraper_screen/scraper_login_screen.dart';
import '../services/screenscraper_service.dart';

class ScraperContent extends StatefulWidget {
  const ScraperContent({super.key});

  @override
  State<ScraperContent> createState() => _ScraperContentState();
}

class _ScraperContentState extends State<ScraperContent> {
  bool _hasCredentials = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _checkCredentials();
  }

  Future<void> _checkCredentials() async {
    final hasCredentials = await ScreenScraperService.hasSavedCredentials();
    if (mounted) {
      setState(() {
        _hasCredentials = hasCredentials;
        _isLoading = false;
      });
    }
  }

  void _onLoginSuccess() {
    setState(() {
      _hasCredentials = true;
    });
  }

  void _onLogout() {
    setState(() {
      _hasCredentials = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_hasCredentials) {
      return NewScraperOptionsScreen(onLogout: _onLogout);
    } else {
      return ScraperLoginScreen(onLoginSuccess: _onLoginSuccess);
    }
  }
}
