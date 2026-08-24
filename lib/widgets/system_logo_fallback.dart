import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

class SystemLogoFallback extends StatelessWidget {
  final String? title;
  final String? shortName;
  final bool isShadow;
  final double? height;
  final double? width;

  const SystemLogoFallback({
    super.key,
    this.title,
    this.shortName,
    this.isShadow = false,
    this.height,
    this.width,
  });

  @override
  Widget build(BuildContext context) {
    final text = shortName ?? title ?? 'SYSTEM';

    return Container(
      height: height,
      width: width,
      padding: EdgeInsets.symmetric(horizontal: 4.r),
      child: Center(
        child: Text(
          text.toUpperCase(),
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Colors.white,
            fontSize: (height != null && height! < 40.r) ? 16.r : 42.r,
            fontWeight: FontWeight.w900,
            letterSpacing: 1,
            shadows: [
              Shadow(blurRadius: 5, color: Colors.black, offset: Offset(3, 3)),
            ],
          ),
        ),
      ),
    );
  }
}
