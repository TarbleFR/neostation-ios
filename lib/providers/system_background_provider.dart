import 'package:flutter/material.dart';

/// Provider responsible for managing the dynamic background image of the system.
///
/// Allows different screens to synchronize and display a consistent background
/// image (e.g., system-specific fanart or global theme backgrounds).
class SystemBackgroundProvider extends ChangeNotifier {
  /// The current background image as a Flutter [ImageProvider].
  ImageProvider? _imageProvider;

  /// The source filesystem path or asset URI of the current background.
  String? _imagePath;

  ImageProvider? get imageProvider => _imageProvider;
  String? get imagePath => _imagePath;

  /// Updates the current background image and notifies observers.
  ///
  /// The [imagePath] is used as a unique key to prevent redundant updates
  /// if the same image is re-assigned.
  void updateImage(ImageProvider provider, {String? imagePath}) {
    if (_imagePath == imagePath && _imageProvider != null) return;

    _imageProvider = provider;
    _imagePath = imagePath;
    notifyListeners();
  }

  /// Clears the current background image to free memory during gameplay.
  void clear() {
    if (_imageProvider == null) return;
    _imageProvider = null;
    _imagePath = null;
    notifyListeners();
  }
}
