import 'dart:math' as math;

import 'package:flutter/material.dart';

const List<int> _projectColorPalette = <int>[
  0xFF2563EB,
  0xFF0EA5E9,
  0xFF14B8A6,
  0xFF16A34A,
  0xFF65A30D,
  0xFFF59E0B,
  0xFFF97316,
  0xFFEF4444,
  0xFFDB2777,
  0xFF7C3AED,
  0xFF4F46E5,
  0xFF0F766E,
];

int autoProjectColorValueById(int projectId) {
  final int index = math.max(0, projectId) % _projectColorPalette.length;
  return _projectColorPalette[index];
}

int generatedProjectColorValueBySeed(int seed) {
  final int safeSeed = math.max(0, seed);
  final double hue = (safeSeed * 137.508) % 360;
  final double saturation = 0.62 + ((safeSeed % 6) * 0.045);
  final double value = 0.78 + ((safeSeed % 5) * 0.035);
  return HSVColor.fromAHSV(
    1,
    hue,
    saturation.clamp(0.62, 0.88),
    value.clamp(0.78, 0.95),
  ).toColor().toARGB32();
}

Color autoProjectColorById(int projectId) {
  return Color(autoProjectColorValueById(projectId));
}
