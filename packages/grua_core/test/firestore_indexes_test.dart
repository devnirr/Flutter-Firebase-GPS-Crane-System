import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every composite query the app makes has to have an index published, or the
/// listener does not fail loudly — it just never emits.
///
/// The bug this pins down: `watchActiveServices` ordered `createdAt` ascending
/// while the only declared index was `status ASC + createdAt DESC`. The
/// dispatcher's panel showed an empty roster — "Todo tranquilo", in green —
/// while a customer sat on the shoulder watching "Buscando grúa". Nothing in
/// the repository is going to catch that: the query is valid Dart and the
/// index file is valid JSON. Only pairing the two does.
void main() {
  /// The index file, wherever the test happens to be run from.
  Map<String, dynamic> readIndexes() {
    var dir = Directory.current;
    for (var i = 0; i < 6; i++) {
      final file = File('${dir.path}/firestore.indexes.json');
      if (file.existsSync()) {
        return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      }
      dir = dir.parent;
    }
    fail('firestore.indexes.json not found above ${Directory.current.path}');
  }

  /// Every declared index as `collection: field dir + field dir`.
  Set<String> declared() {
    final indexes = readIndexes()['indexes'] as List<dynamic>;
    return {
      for (final raw in indexes)
        () {
          final index = raw as Map<String, dynamic>;
          final fields = (index['fields'] as List<dynamic>)
              .cast<Map<String, dynamic>>()
              .map((f) => '${f['fieldPath']} ${f['order'] ?? f['arrayConfig']}')
              .join(' + ');
          return '${index['collectionGroup']}: $fields';
        }(),
    };
  }

  test("the dispatcher's open-jobs query has an index", () {
    // `where('status', whereIn: …).orderBy('createdAt', descending: true)`
    // in FirebaseServiceRepository.watchActiveServices. Both halves must
    // change together: flipping the order without publishing the ascending
    // index blanks the operations panel.
    expect(
      declared(),
      contains('services: status ASCENDING + createdAt DESCENDING'),
    );
  });

  test('the "do I have a job in flight" queries have theirs', () {
    expect(
      declared(),
      containsAll([
        'services: clientId ASCENDING + status ASCENDING + createdAt DESCENDING',
        'services: driverId ASCENDING + status ASCENDING + createdAt DESCENDING',
      ]),
    );
  });

  test('the history and chat lists have theirs', () {
    expect(
      declared(),
      containsAll([
        'services: clientId ASCENDING + createdAt DESCENDING',
        'services: driverId ASCENDING + createdAt DESCENDING',
        'chatRequests: clientId ASCENDING + createdAt DESCENDING',
        'chatRequests: driverId ASCENDING + createdAt DESCENDING',
      ]),
    );
  });

  test('the call queries have theirs', () {
    // The app watching for a call ringing for it, and the server refusing a
    // second call on a service, or in a pre-job chat, that already has one.
    expect(
      declared(),
      containsAll([
        'calls: calleeId ASCENDING + state ASCENDING',
        'calls: serviceId ASCENDING + state ASCENDING',
        'calls: chatRequestId ASCENDING + state ASCENDING',
      ]),
    );
  });

  test("one chofer's cortes have theirs", () {
    // `watchCashSettlements(driverId: …)`: equality plus newest first.
    expect(
      declared(),
      contains('cashSettlements: driverId ASCENDING + createdAt DESCENDING'),
    );
  });

  test("the offer sweep and the chofer's open offer have theirs", () {
    expect(
      declared(),
      containsAll([
        'services: status ASCENDING + dispatch.offerExpiresAt ASCENDING',
        'offers: driverId ASCENDING + state ASCENDING',
      ]),
    );
  });
}
