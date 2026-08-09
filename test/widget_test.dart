import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:record_and_paste/main.dart';

void main() {
  testWidgets('App si avvia e mostra la schermata principale', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(RecordAndPasteApp());
    await tester.pump();

    expect(find.byIcon(Icons.settings), findsOneWidget);
  });
}
