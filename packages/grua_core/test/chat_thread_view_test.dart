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
    Future<Result<void>> Function(List<String> ids)? onDeleteMessages,
    Future<void> Function(List<String> urls)? onDownloadImages,
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
      onDeleteMessages: onDeleteMessages,
      onDownloadImages: onDownloadImages,
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

  testWidgets('a long conversation opens on the last thing said', (
    tester,
  ) async {
    final sentAt = DateTime.utc(2026, 9, 12, 1, 30);
    await tester.pumpWidget(
      harness(
        messages: [
          for (var i = 1; i <= 40; i++)
            ChatMessage(
              id: 'm-$i',
              senderId: i.isEven ? me : them,
              senderRole: i.isEven ? UserRole.client : UserRole.driver,
              text: 'Mensaje $i',
              clientMsgId: 'm-$i',
              sentAt: sentAt.add(Duration(minutes: i)),
            ),
        ],
      ),
    );
    await tester.pump();

    // The end of the history is what somebody came to read.
    expect(find.text('Mensaje 40'), findsOneWidget);
    expect(find.text('Mensaje 39'), findsOneWidget);
    // The start of it is far above, and not even built.
    expect(find.text('Mensaje 1'), findsNothing);

    // The newest sits at the bottom, above the composer.
    final newest = tester.getRect(find.text('Mensaje 40'));
    final older = tester.getRect(find.text('Mensaje 39'));
    expect(newest.top, greaterThan(older.top));
    expect(newest.bottom, lessThan(tester.getRect(find.byType(TextField)).top));

    // Scrolling back reaches the beginning.
    await tester.drag(find.text('Mensaje 40'), const Offset(0, 2000));
    await tester.pumpAndSettle();
    expect(find.text('Mensaje 40'), findsNothing);
  });

  group('picking messages out of a conversation', () {
    final sentAt = DateTime.utc(2026, 9, 12, 2, 30);

    ChatMessage mine(String id, {String text = 'Mío', String image = ''}) =>
        ChatMessage(
          id: id,
          senderId: me,
          senderRole: UserRole.client,
          text: text,
          imageUrl: image,
          clientMsgId: id,
          sentAt: sentAt,
        );

    ChatMessage theirs(String id, {String text = 'Suyo'}) => ChatMessage(
      id: id,
      senderId: them,
      senderRole: UserRole.driver,
      text: text,
      clientMsgId: id,
      sentAt: sentAt,
    );

    testWidgets('a long press starts the selection with that message ticked', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(messages: [mine('m-1'), theirs('m-2')]),
      );
      await tester.pump();

      // Nothing until asked for.
      expect(find.byKey(const Key('selection-close')), findsNothing);
      expect(find.byKey(const Key('selected-mark')), findsNothing);

      await tester.longPress(find.text('Mío'));
      await tester.pumpAndSettle();

      // The bar takes the message box's place, and the one held is ticked.
      expect(find.text('1 seleccionado'), findsOneWidget);
      expect(find.text('Escribe un mensaje…'), findsNothing);
      // The header still says who this conversation is with.
      expect(find.text('Chofer'), findsOneWidget);
      expect(find.byKey(const Key('selected-mark')), findsOneWidget);
      expect(find.byKey(const Key('unselected-mark')), findsOneWidget);

      // At the bottom, where the box was — not up in the header.
      final bar = tester.getRect(find.text('1 seleccionado'));
      final header = tester.getRect(find.text('Chofer'));
      expect(bar.top, greaterThan(header.bottom));
      expect(
        bar.center.dy,
        greaterThan(tester.getRect(find.byType(ListView)).center.dy),
      );

      // The mark sits to the right of the message it belongs to.
      final mark = tester.getRect(find.byKey(const Key('selected-mark')));
      expect(mark.left, greaterThan(tester.getRect(find.text('Mío')).right));

      // Tapping another adds it; tapping it again takes it back out.
      await tester.tap(find.text('Suyo'));
      await tester.pumpAndSettle();
      expect(find.text('2 seleccionados'), findsOneWidget);
      await tester.tap(find.text('Suyo'));
      await tester.pumpAndSettle();
      expect(find.text('1 seleccionado'), findsOneWidget);

      // And the cross gives the message box back.
      await tester.tap(find.byKey(const Key('selection-close')));
      await tester.pumpAndSettle();
      expect(find.text('Escribe un mensaje…'), findsOneWidget);
      expect(find.text('1 seleccionado'), findsNothing);
      expect(find.byKey(const Key('selected-mark')), findsNothing);
    });

    testWidgets('delete is offered for your own words only', (tester) async {
      var asked = <String>[];
      await tester.pumpWidget(
        harness(
          messages: [mine('m-1'), theirs('m-2')],
          onDeleteMessages: (ids) async {
            asked = ids;
            return const Result.ok(null);
          },
        ),
      );
      await tester.pump();

      // Theirs: nothing to take back.
      await tester.longPress(find.text('Suyo'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('selection-delete')))
            .onPressed,
        isNull,
      );

      // Mine, and it asks before taking it off both screens.
      await tester.tap(find.text('Suyo'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('Mío'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('selection-delete')));
      await tester.pumpAndSettle();
      expect(find.text('¿Eliminar el mensaje?'), findsOneWidget);

      await tester.tap(find.byKey(const Key('confirm-delete')));
      await tester.pumpAndSettle();
      expect(asked, ['m-1']);
      // The selection is over once it has been acted on.
      expect(find.byKey(const Key('selection-close')), findsNothing);
    });

    testWidgets('download waits for a photo to be among the chosen', (
      tester,
    ) async {
      var saved = <String>[];
      await tester.pumpWidget(
        harness(
          messages: [
            mine('m-1'),
            mine('m-2', text: '', image: 'https://example/photo.jpg'),
          ],
          onDownloadImages: (urls) async => saved = urls,
        ),
      );
      await tester.pump();

      Object? downloadAction() => tester
          .widget<IconButton>(find.byKey(const Key('selection-download')))
          .onPressed;

      // Words alone: nothing to save.
      await tester.longPress(find.text('Mío'));
      await tester.pumpAndSettle();
      expect(downloadAction(), isNull);

      // With the photo picked, it works and hands over that one URL.
      await tester.tap(find.byType(Image).first);
      await tester.pumpAndSettle();
      expect(downloadAction(), isNotNull);
      await tester.tap(find.byKey(const Key('selection-download')));
      await tester.pumpAndSettle();
      expect(saved, ['https://example/photo.jpg']);
    });

    testWidgets('a retracted message says so in place of what it said', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(
          messages: [
            ChatMessage(
              id: 'm-1',
              senderId: me,
              senderRole: UserRole.client,
              clientMsgId: 'm-1',
              sentAt: sentAt,
              deletedAt: sentAt.add(const Duration(minutes: 1)),
            ),
          ],
        ),
      );
      await tester.pump();

      expect(find.text('Se eliminó este mensaje'), findsOneWidget);
      // Nothing left to report about delivery.
      expect(find.byKey(const Key('tick-sent')), findsNothing);
      expect(find.byKey(const Key('tick-read')), findsNothing);
    });
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
