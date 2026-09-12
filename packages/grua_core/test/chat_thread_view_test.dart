import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:intl/date_symbol_data_local.dart';

/// What a conversation tells you without words: whether what you sent arrived,
/// whether it was read, and whether the other side is writing back.
Future<void> main() async {
  setUpAll(() => initializeDateFormatting('es_DO'));

  const me = 'client-1';
  const them = 'driver-1';

  ChatMessage message({
    required String id,
    required String from,
    DateTime? sentAt,
    DateTime? readAt,
  }) => ChatMessage(
    id: id,
    senderId: from,
    senderRole: from == me ? UserRole.client : UserRole.driver,
    text: 'Hola',
    clientMsgId: id,
    sentAt: sentAt,
    readAt: readAt,
  );

  Widget harness({
    required List<ChatMessage> messages,
    bool otherTyping = false,
    ValueChanged<bool>? onTyping,
  }) => MaterialApp(
    theme: AppTheme.phone(),
    home: ChatThreadView(
      title: 'Chofer',
      subtitle: 'Grúa en camino',
      messages: messages,
      myUid: me,
      canWrite: true,
      closedNotice: 'Cerrado',
      emptyMessage: 'Sin mensajes',
      otherTyping: otherTyping,
      onTyping: onTyping,
      onSend: (_, _) async => const Result.ok(null),
    ),
  );

  testWidgets('a message of mine shows one tick when sent and two when read', (
    tester,
  ) async {
    final sentAt = DateTime.utc(2026, 9, 11, 21, 54);

    await tester.pumpWidget(
      harness(
        messages: [
          message(id: 'm-1', from: me),
          message(id: 'm-2', from: me, sentAt: sentAt),
          message(
            id: 'm-3',
            from: me,
            sentAt: sentAt,
            readAt: sentAt.add(const Duration(minutes: 1)),
          ),
          message(id: 'm-4', from: them, sentAt: sentAt),
        ],
      ),
    );
    await tester.pump();

    // On its way, delivered, read.
    expect(find.byKey(const Key('tick-pending')), findsOneWidget);
    expect(find.byKey(const Key('tick-sent')), findsOneWidget);
    expect(find.byKey(const Key('tick-read')), findsOneWidget);

    // The read one is the double tick, and it is the coloured one.
    final read = tester.widget<Icon>(find.byKey(const Key('tick-read')));
    expect(read.icon, Icons.done_all);
    expect(read.color, BrandColors.readTick);
    expect(
      tester.widget<Icon>(find.byKey(const Key('tick-sent'))).icon,
      Icons.check,
    );

    // Four messages, three ticks: the other side's carries none, since what
    // they know about my reading is none of my business here.
    expect(find.byIcon(Icons.done_all), findsOneWidget);
  });

  testWidgets('the other side typing shows just above the message box', (
    tester,
  ) async {
    await tester.pumpWidget(harness(messages: const []));
    await tester.pump();
    expect(find.byKey(const Key('typing-indicator')), findsNothing);

    await tester.pumpWidget(harness(messages: const [], otherTyping: true));
    await tester.pump();
    expect(find.text('Escribiendo…'), findsOneWidget);

    // Over the box the answer gets typed into, not up beside the name — and
    // the subtitle keeps saying what the conversation is.
    final line = tester.getRect(find.byKey(const Key('typing-indicator')));
    final box = tester.getRect(find.byType(TextField));
    final title = tester.getRect(find.text('Grúa en camino'));
    expect(line.bottom, lessThanOrEqualTo(box.top));
    expect(line.top, greaterThan(title.bottom));
  });

  testWidgets('typing is announced once and withdrawn after a pause', (
    tester,
  ) async {
    final said = <bool>[];
    await tester.pumpWidget(harness(messages: const [], onTyping: said.add));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'Ho');
    await tester.pump();
    expect(said, [true]);

    // More keystrokes inside the window cost nothing.
    await tester.enterText(find.byType(TextField), 'Hola');
    await tester.pump(const Duration(milliseconds: 500));
    expect(said, [true]);

    // Quiet for a moment, and it is withdrawn on its own.
    await tester.pump(const Duration(seconds: 4));
    expect(said, [true, false]);

    // Clearing the box stops it too, without waiting.
    await tester.enterText(find.byType(TextField), 'Otra');
    await tester.pump();
    expect(said, [true, false, true]);
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    expect(said, [true, false, true, false]);
  });
}
