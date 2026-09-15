import 'package:flutter/material.dart';

ThemeData buildTheme(Brightness brightness) {
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3B6E4E), brightness: brightness),
  );
}
