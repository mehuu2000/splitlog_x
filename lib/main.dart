import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'core/services/session_storage_service.dart';
import 'features/session/desktop/desktop_session_view.dart';

void main() {
  runApp(const SplitLogApp());
}

class SplitLogApp extends StatelessWidget {
  const SplitLogApp({super.key, this.storage});

  final SessionStorageService? storage;

  @override
  Widget build(BuildContext context) {
    final isWindows =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
    final baseTheme = ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2F6FED)),
      useMaterial3: true,
      inputDecorationTheme: const InputDecorationThemeData(
        focusColor: Colors.transparent,
        hoverColor: Colors.transparent,
      ),
      fontFamily: isWindows ? 'Inter' : null,
      fontFamilyFallback: isWindows
          ? const [
              'Noto Sans JP',
              'Yu Gothic UI',
              'Meiryo UI',
              'Meiryo',
              'sans-serif',
            ]
          : const ['Hiragino Sans', 'Yu Gothic', 'Meiryo', 'sans-serif'],
    );

    return MaterialApp(
      title: 'SplitLog',
      debugShowCheckedModeBanner: false,
      theme: baseTheme,
      home: SplitLogDesktopPreviewPage(storage: storage),
    );
  }
}

class SplitLogDesktopPreviewPage extends StatelessWidget {
  const SplitLogDesktopPreviewPage({super.key, this.storage});

  final SessionStorageService? storage;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFE9EBEF),
      body: Center(child: DesktopSessionView(storage: storage)),
    );
  }
}
