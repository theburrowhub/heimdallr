import 'package:flutter/material.dart';

class SeverityBadge extends StatelessWidget {
  final String severity;

  const SeverityBadge({super.key, required this.severity});

  Color get _color {
    switch (severity.toLowerCase()) {
      case 'high':
        return Colors.red.shade700;
      case 'medium':
        return Colors.orange.shade700;
      default:
        return Colors.green.shade700;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: _color,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        severity.toUpperCase(),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
