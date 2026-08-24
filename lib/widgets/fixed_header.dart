import 'package:flutter/material.dart';
import 'header.dart';

class FixedHeader extends StatelessWidget {
  final int selectedTabIndex;
  final Function(int) onTabSelected;

  const FixedHeader({
    super.key,
    required this.selectedTabIndex,
    required this.onTabSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Header(
      selectedTabIndex: selectedTabIndex,
      onTabSelected: onTabSelected,
    );
  }
}
