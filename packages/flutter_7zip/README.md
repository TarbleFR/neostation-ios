# flutter_7zip

A flutter plugin to decompress 7z files.

## Getting Started

Add this to your package's pubspec.yaml file:

```yaml
dependencies:
  flutter_7zip: 
    git:
      url: https://github.com/wgh136/flutter_7zip.git
```

## Usage

### Example
```dart
import 'package:flutter_7zip/flutter_7zip.dart';

void extract(String archivePath, String outputPath) {
  var archive = SZArchive.open(archivePath);
  for (var i = 0; i < archive.numFiles; i++) {
    var file = archive.getFile(i);
    var outPath = outputPath + Platform.pathSeparator + file.name;
    if (file.isDirectory) {
      Directory(outPath).createSync(recursive: true);
    } else {
      archive.extractToFile(i, outPath);
    }
  }
  archive.dispose();
}
```

### Utilities
```dart
import 'package:flutter_7zip/flutter_7zip.dart';

void main() {
  // Extract archive to a directory
  SZArchive.extract('path/to/archive.7z', 'path/to/output');
  // Extract archive to a directory with multiple Isolates
  SZArchive.extractIsolates(
    'path/to/archive.7z', 
    'path/to/output', 
    4, // Number of isolates
  );
}
```