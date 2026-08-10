import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/services/session_storage_service.dart';
import 'features/session/desktop/desktop_session_view.dart';
import 'main_mobile.dart' as mobile;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final targetPlatform = defaultTargetPlatform;
  if (_isMobilePlatform(targetPlatform)) {
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
    ]);
  }
  runApp(SplitLogPlatformApp(platform: targetPlatform));
}

bool _isMobilePlatform(TargetPlatform platform) {
  return !kIsWeb &&
      (platform == TargetPlatform.iOS || platform == TargetPlatform.android);
}

class SplitLogPlatformApp extends StatelessWidget {
  const SplitLogPlatformApp({super.key, this.storage, this.platform});

  final SessionStorageService? storage;
  final TargetPlatform? platform;

  @override
  Widget build(BuildContext context) {
    final targetPlatform = platform ?? defaultTargetPlatform;
    if (_isMobilePlatform(targetPlatform)) {
      return mobile.SplitLogMobileApp(storage: storage);
    }
    return SplitLogApp(storage: storage, platform: targetPlatform);
  }
}

class SplitLogApp extends StatelessWidget {
  const SplitLogApp({super.key, this.storage, this.platform});

  final SessionStorageService? storage;
  final TargetPlatform? platform;

  @override
  Widget build(BuildContext context) {
    final targetPlatform = platform ?? defaultTargetPlatform;
    final isWindows = !kIsWeb && targetPlatform == TargetPlatform.windows;
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
      builder: isWindows
          ? (context, child) => DefaultTextHeightBehavior(
              key: const ValueKey<String>('windows-even-text-leading'),
              textHeightBehavior: const TextHeightBehavior(
                leadingDistribution: TextLeadingDistribution.even,
              ),
              child: child ?? const SizedBox.shrink(),
            )
          : null,
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
