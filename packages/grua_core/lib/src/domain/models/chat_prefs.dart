import 'package:flutter/foundation.dart';

import '../../data/converters.dart';
import 'dispatch_models.dart';

/// What one person did to one conversation, at
/// `users/{uid}/chatState/{threadKey}`.
///
/// Private to them. Clearing or deleting a chat takes it off their own screen
/// and leaves the other side's untouched — the way every messenger behaves,
/// and the only honest option here, since the messages belong to both.
@immutable
class ChatThreadPrefs {
  const ChatThreadPrefs({this.clearedAt, this.deletedAt});

  factory ChatThreadPrefs.fromJson(Map<String, dynamic> json) {
    const time = NullableTimestampConverter();
    return ChatThreadPrefs(
      clearedAt: time.fromJson(json['clearedAt']),
      deletedAt: time.fromJson(json['deletedAt']),
    );
  }

  /// A conversation nobody has touched.
  static const none = ChatThreadPrefs();

  /// Messages sent at or before this are not shown to this person again.
  final DateTime? clearedAt;

  /// When they deleted the conversation. It stays off their list until
  /// something new is said in it.
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;

  /// Whether [message] is one of the ones they cleared away.
  ///
  /// A message with no `sentAt` is still on its way to the server, so it was
  /// written after the clear by definition and stays on screen.
  bool hides(ChatMessage message) {
    final cleared = clearedAt;
    final sentAt = message.sentAt;
    if (cleared == null || sentAt == null) return false;
    return !sentAt.isAfter(cleared);
  }

  /// Whether the conversation is back on their list: something was said in it
  /// after they deleted it.
  bool showsAgain(DateTime? lastMessageAt) {
    final deleted = deletedAt;
    if (deleted == null) return true;
    return lastMessageAt != null && lastMessageAt.isAfter(deleted);
  }
}
