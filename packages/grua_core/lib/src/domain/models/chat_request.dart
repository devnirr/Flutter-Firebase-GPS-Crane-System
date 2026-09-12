import 'package:flutter/foundation.dart';

import '../../data/converters.dart';

/// Where a chat request stands on the server, at `chatRequests/{id}.status`.
enum ChatRequestStatus {
  /// Sent to the chofer, not answered yet.
  pending('pending'),

  /// The chofer said yes: the conversation is open.
  accepted('accepted'),

  /// The chofer said no, or let it go from their side.
  declined('declined'),

  /// The customer withdrew it before an answer.
  cancelled('cancelled'),

  /// One of the two ended the conversation.
  closed('closed'),

  unknown('unknown');

  const ChatRequestStatus(this.wire);

  final String wire;

  static ChatRequestStatus fromWire(String? wire) {
    for (final status in ChatRequestStatus.values) {
      if (status.wire == wire) return status;
    }
    return ChatRequestStatus.unknown;
  }
}

/// What a request can still do, which is what every screen actually needs.
enum ChatRequestPhase {
  /// Waiting for the chofer's answer.
  waiting,

  /// Accepted and not closed: both sides may write.
  open,

  /// Answered no, withdrawn, closed, or lapsed. Read-only.
  over,
}

/// A customer asking the chofer of a nearby truck to talk, before any job
/// exists, at `chatRequests/{id}`.
///
/// Server-written: the customer sends a sealed truck ref and never learns who
/// drives until the chofer accepts, when [driverName] is filled in. The
/// messages live under it at `chatRequests/{id}/messages`, shaped like a job's.
@immutable
class ChatRequest {
  const ChatRequest({
    required this.id,
    required this.clientId,
    required this.driverId,
    this.clientName = '',
    this.driverName = '',
    this.driverPhotoUrl = '',
    this.status = ChatRequestStatus.pending,
    this.createdAt,
    this.expiresAt,
    this.respondedAt,
    this.closesAt,
  });

  factory ChatRequest.fromJson(Map<String, dynamic> json) {
    const time = NullableTimestampConverter();
    return ChatRequest(
      id: json['id'] as String? ?? '',
      clientId: json['clientId'] as String? ?? '',
      driverId: json['driverId'] as String? ?? '',
      clientName: json['clientName'] as String? ?? '',
      driverName: json['driverName'] as String? ?? '',
      driverPhotoUrl: json['driverPhotoUrl'] as String? ?? '',
      status: ChatRequestStatus.fromWire(json['status'] as String?),
      createdAt: time.fromJson(json['createdAt']),
      expiresAt: time.fromJson(json['expiresAt']),
      respondedAt: time.fromJson(json['respondedAt']),
      closesAt: time.fromJson(json['closesAt']),
    );
  }

  final String id;
  final String clientId;
  final String driverId;
  final String clientName;

  /// Empty until the chofer accepts: the customer does not learn who drives
  /// the truck before the chofer chooses to answer.
  final String driverName;

  /// The chofer's face, filled in with the name when they accept. Empty
  /// before that: a customer learns nothing about a truck they only tapped.
  final String driverPhotoUrl;
  final ChatRequestStatus status;
  final DateTime? createdAt;

  /// When an unanswered request lapses.
  final DateTime? expiresAt;
  final DateTime? respondedAt;

  /// When an accepted conversation closes on its own.
  final DateTime? closesAt;

  /// Mirrors `chatRequestPhase` in the functions. A pending request past its
  /// expiry is over even though the document still says pending.
  ChatRequestPhase phaseAt(DateTime now) => switch (status) {
        ChatRequestStatus.pending => expiresAt == null || now.isBefore(expiresAt!)
            ? ChatRequestPhase.waiting
            : ChatRequestPhase.over,
        ChatRequestStatus.accepted => closesAt == null || now.isBefore(closesAt!)
            ? ChatRequestPhase.open
            : ChatRequestPhase.over,
        _ => ChatRequestPhase.over,
      };

  ChatRequest copyWith({
    ChatRequestStatus? status,
    String? driverName,
    String? driverPhotoUrl,
    DateTime? respondedAt,
    DateTime? closesAt,
  }) =>
      ChatRequest(
        id: id,
        clientId: clientId,
        driverId: driverId,
        clientName: clientName,
        driverName: driverName ?? this.driverName,
        driverPhotoUrl: driverPhotoUrl ?? this.driverPhotoUrl,
        status: status ?? this.status,
        createdAt: createdAt,
        expiresAt: expiresAt,
        respondedAt: respondedAt ?? this.respondedAt,
        closesAt: closesAt ?? this.closesAt,
      );

  /// For the typed collection reference only. The apps never write a request.
  Map<String, dynamic> toJson() {
    const time = NullableTimestampConverter();
    return {
      'id': id,
      'clientId': clientId,
      'driverId': driverId,
      'clientName': clientName,
      'driverName': driverName,
      'driverPhotoUrl': driverPhotoUrl,
      'status': status.wire,
      'createdAt': time.toJson(createdAt),
      'expiresAt': time.toJson(expiresAt),
      'respondedAt': time.toJson(respondedAt),
      'closesAt': time.toJson(closesAt),
    };
  }
}
