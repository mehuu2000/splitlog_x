import 'package:flutter/material.dart';

import 'features/session/desktop/desktop_session_view.dart';

void main() {
  runApp(const SplitLogApp());
}

class SplitLogApp extends StatelessWidget {
  const SplitLogApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SplitLog',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2F6FED)),
        useMaterial3: true,
        fontFamilyFallback: const [
          'Hiragino Sans',
          'Yu Gothic',
          'Meiryo',
          'sans-serif',
        ],
      ),
      home: const SplitLogDesktopPreviewPage(),
    );
  }
}

class SplitLogDesktopPreviewPage extends StatelessWidget {
  const SplitLogDesktopPreviewPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFFE9EBEF),
      body: Center(child: DesktopSessionView()),
    );
  }
}
