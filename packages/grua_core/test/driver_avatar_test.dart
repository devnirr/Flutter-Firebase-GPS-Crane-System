import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';

/// The bug: deleting a chofer from the roster showed the deleted chofer's
/// photo on the row below it.
///
/// A list that loses a row shifts every row under it up, and Flutter matches
/// the old widgets to the new ones by position. The row's image element was
/// therefore handed the next chofer's URL, and — since a photo takes a moment
/// to arrive — kept painting the frame it already had in the meantime.
void main() {
  Widget roster(List<(String name, String photo)> people) => MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          // Deliberately unkeyed, as a plain `for` over a list is: the avatar
          // itself has to survive this.
          for (final (name, photo) in people)
            DriverAvatar(name: name, photoUrl: photo),
        ],
      ),
    ),
  );

  testWidgets('an avatar does not inherit the element of the row above it', (
    tester,
  ) async {
    const uno = 'https://example.com/uno.png';
    const dos = 'https://example.com/dos.png';

    await tester.pumpWidget(
      roster([('Chofer Uno', uno), ('Chofer Dos', dos)]),
    );
    final first = tester.element(find.byType(Image).first);

    // The first chofer is deleted: the second takes their place in the list.
    await tester.pumpWidget(roster([('Chofer Dos', dos)]));

    final remaining = tester.element(find.byType(Image).first);
    expect(
      identical(remaining, first),
      isFalse,
      reason: 'the row kept the deleted chofer\'s image element, so it would '
          'go on painting their photo until the new one loaded',
    );
    expect(
      (tester.widget<Image>(find.byType(Image)).image as NetworkImage).url,
      dos,
    );
  });

  testWidgets('the same photo in the same place is not reloaded', (
    tester,
  ) async {
    const uno = 'https://example.com/uno.png';
    await tester.pumpWidget(roster([('Chofer Uno', uno)]));
    final before = tester.element(find.byType(Image).first);

    // A rebuild that changes nothing about the photo — a presence dot moving,
    // a name edited — must not throw the loaded image away.
    await tester.pumpWidget(roster([('Chofer Uno Editado', uno)]));

    expect(identical(tester.element(find.byType(Image).first), before), isTrue);
  });
}
