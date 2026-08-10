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
    const accent = Color(0xFF2563EB);
    final colorScheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.light,
      surface: Colors.white,
    );
    return MaterialApp(
      title: 'SplitLog',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: colorScheme,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF5F7FA),
        splashFactory: InkSparkle.splashFactory,
        inputDecorationTheme: const InputDecorationThemeData(
          focusColor: Colors.transparent,
          hoverColor: Colors.transparent,
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          showDragHandle: true,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
          ),
        ),
        dialogTheme: const DialogThemeData(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
        ),
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: Color(0xFF171A21),
          contentTextStyle: TextStyle(color: Colors.white, fontSize: 13),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
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
