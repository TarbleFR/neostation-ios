import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

/// Reusable settings title component with title and subtitle
class SettingsTitle extends StatelessWidget {
  final String title;
  final String? subtitle;

  const SettingsTitle({super.key, required this.title, this.subtitle});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.titleLarge?.copyWith(fontSize: 14.r),
        ),
        if (subtitle != null) ...[
          SizedBox(height: 8.r),
          Text(
            subtitle!,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontSize: 9.r,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ],
    );
  }
}
