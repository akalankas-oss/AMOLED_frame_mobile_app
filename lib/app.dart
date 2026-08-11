import 'package:flutter/material.dart';

import 'pages/frame_page.dart';

class AmoledFrameApp extends StatelessWidget {
  const AmoledFrameApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AMOLED Frame',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const FramePage(),
    );
  }
}
