import 'package:flutter_test/flutter_test.dart';

import 'package:amoled_frame_app/main.dart';

void main() {
  testWidgets('App renders without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(const AmoledFrameApp());
    expect(find.text('AMOLED Frame'), findsOneWidget);
    expect(find.text('Pick Image'), findsOneWidget);
  });
}
