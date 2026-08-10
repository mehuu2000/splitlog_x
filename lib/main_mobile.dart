import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/services/session_storage_service.dart';
import 'features/session/mobile/mobile_session_view.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
  ]);
  runApp(const SplitLogMobileApp());
}

class SplitLogMobileApp extends StatelessWidget {
  const SplitLogMobileApp({super.key, this.storage});

  final SessionStorageService? storage;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SplitLog',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2F6FED)),
        useMaterial3: true,
        inputDecorationTheme: const InputDecorationThemeData(
          focusColor: Colors.transparent,
          hoverColor: Colors.transparent,
        ),
        fontFamilyFallback: const [
          'Hiragino Sans',
          'Yu Gothic',
          'Meiryo',
          'sans-serif',
        ],
      ),
      home: MobileSessionView(storage: storage),
    );
  }
}
