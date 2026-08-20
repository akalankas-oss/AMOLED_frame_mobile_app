import 'package:flutter/material.dart';

import 'pages/frame_page.dart';
import 'widgets/neumorphic_components.dart';

class AmoledFrameApp extends StatelessWidget {
  const AmoledFrameApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AMOLED Frame',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.black,
        canvasColor: AppColors.black,
        colorScheme: const ColorScheme.dark(
          primary: AppColors.cyanAccent,
          secondary: AppColors.pinkAccent,
          surface: AppColors.surface,
          error: Colors.redAccent,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          titleTextStyle: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
          iconTheme: IconThemeData(color: Colors.white),
        ),
        sliderTheme: SliderThemeData(
          activeTrackColor: AppColors.cyanAccent,
          inactiveTrackColor: AppColors.surfaceElevatedLighter,
          thumbColor: AppColors.cyanAccent,
          overlayColor: AppColors.cyanAccent.withValues(alpha: 0.2),
          trackHeight: 4,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
        ),
        useMaterial3: true,
      ),
      home: const FramePage(),
    );
  }
}
