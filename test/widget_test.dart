import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:halcyn/src/rust/api/player.dart';
import 'package:halcyn/src/signal_path_view.dart';

void main() {
  Widget wrap(SignalPath path) => MaterialApp(
    home: Scaffold(body: SignalPathView(path: path)),
  );

  testWidgets('shows a bit-exact path', (tester) async {
    await tester.pumpWidget(
      wrap(
        const SignalPath(
          source: 'FLAC · 24-bit · 48 kHz · stereo',
          processing: 'Bit-exact',
          output: 'PipeWire · 32-bit · 48 kHz',
          bitExact: true,
        ),
      ),
    );
    expect(find.text('FLAC · 24-bit · 48 kHz · stereo'), findsOneWidget);
    expect(find.text('Bit-exact'), findsNWidgets(2));
  });

  testWidgets('shows a resampled path and its warning', (tester) async {
    await tester.pumpWidget(
      wrap(
        const SignalPath(
          source: 'FLAC · 16-bit · 44.1 kHz · stereo',
          processing: 'Resampled 44.1 kHz → 48 kHz',
          output: 'PipeWire · 32-bit · 48 kHz',
          bitExact: false,
          warning: 'PipeWire kept the graph at 48 kHz.',
        ),
      ),
    );
    expect(find.text('Resampled'), findsOneWidget);
    expect(find.text('PipeWire kept the graph at 48 kHz.'), findsOneWidget);
  });
}
