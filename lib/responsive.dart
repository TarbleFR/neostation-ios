import 'package:flutter/material.dart';

class Responsive extends StatelessWidget {
  final Widget handheldXS;
  final Widget handheldSmall;
  final Widget handheldMedium;
  final Widget handheldLarge;
  final Widget handheldXL;

  const Responsive({
    super.key,
    required this.handheldXS,
    required this.handheldSmall,
    required this.handheldMedium,
    required this.handheldLarge,
    required this.handheldXL,
  });

  // This size work fine on my design, maybe you need some customization depends on your design

  // Breakpoints ajustados para dispositivos gaming con DPI alto
  static bool isHandheldXS(BuildContext context) =>
      MediaQuery.of(context).size.width < 560;

  static bool isHandheldSmall(BuildContext context) =>
      MediaQuery.of(context).size.width < 690 && // era 700
      MediaQuery.of(context).size.width >= 560;

  static bool isHandheldMedium(BuildContext context) =>
      MediaQuery.of(context).size.width <
          840 && // era 960 (reducido para que RP5 sea Large)
      MediaQuery.of(context).size.width >= 690; // era 700

  static bool isHandheldLarge(BuildContext context) =>
      MediaQuery.of(context).size.width < 1280 && // era 1660
      MediaQuery.of(context).size.width >=
          840; // era 960 (reducido para incluir RP5)

  static bool isHandheldXLarge(BuildContext context) =>
      MediaQuery.of(context).size.width >= 1280; // era 1660

  // Métodos alternativos basados en tamaño físico (para DPI alto)

  /// Obtener el crossAxisCount para theme selection grid
  /// Grid de selección de temas optimizado para previews
  static int getThemesCrossAxisCount(BuildContext context) {
    if (isHandheldXLarge(context)) return 6; // Desktop muy grande
    if (isHandheldLarge(context)) return 5; // Desktop grande
    if (isHandheldMedium(context)) return 4; // Desktop/tablet
    if (isHandheldSmall(context)) return 4; // Tablet
    return 4; // Móvil pequeño
  }

  /// Convierte el tamaño de card del usuario ('S', 'M', 'L', 'XL') a columnas.
  static int getSystemsCrossAxisCountFromSize(String size) {
    switch (size) {
      case 'S':
        return 7;
      case 'M':
        return 6;
      case 'L':
        return 5;
      case 'XL':
        return 4;
      default:
        return 6;
    }
  }

  /// Obtener el crossAxisCount para el grid de Apps de Android
  /// 10 para pantallas grandes, menos para pequeñas
  static int getAndroidAppsCrossAxisCount(BuildContext context) {
    if (isHandheldXLarge(context)) return 10;
    if (isHandheldLarge(context)) return 10;
    if (isHandheldMedium(context)) return 8;
    if (isHandheldSmall(context)) return 6;
    return 5; // HandheldXS
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    if (size.width >= 1280) {
      // era 1660
      return handheldXL;
    }
    // If our width is more than 840 then we consider it a handheldLarge (RP5 entra aquí)
    if (size.width >= 840) {
      // era 960 (reducido para incluir RP5)
      return handheldLarge;
    }
    // If width is between 690 and 840 we consider it as handheldMedium
    else if (size.width >= 690) {
      // era 700
      return handheldMedium;
    }
    // If width is between 560 and 690 we consider it as handheldSmall
    else if (size.width >= 560) {
      return handheldSmall;
    }
    // Or less than 560 we called it extra small
    else {
      return handheldXS;
    }
  }
}
