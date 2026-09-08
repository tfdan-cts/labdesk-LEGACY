/// The console's view of a session's chat.
///
/// Pure values: no Flutter, no FFI, no bridge. The chat itself lives in a
/// `ChatModel` inside whichever window holds the session, and the console can
/// only reach it over the window channel, which carries strings. These types
/// are what travels on that channel and what the Sessions screen renders, so
/// the same transcript is described once for both ends.
library;

import 'dart:convert';

/// Who wrote a line. Named for the reader, not for the protocol: the operator
/// at this console is always `mine`, whichever way the session was opened.
enum ChatFrom { mine, peer }

/// Which way the session was opened.
///
/// `outgoing` is a session this machine started against another machine, held
/// by a remote-desktop window. `incoming` is somebody connected to this
/// machine, held by the connection manager.
enum SessionDirection { outgoing, incoming }

String _nameOf(Enum e) => e.name;

T _enumFrom<T extends Enum>(List<T> values, Object? name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}

/// One message in a session's chat.
class ChatLine {
  const ChatLine({required this.from, required this.text, required this.at});

  final ChatFrom from;
  final String text;
  final DateTime at;

  bool get isMine => from == ChatFrom.mine;

  Map<String, dynamic> toJson() => {
        'from': _nameOf(from),
        'text': text,
        // Sent as an ISO 8601 string rather than a timestamp so the payload
        // stays readable when it is being debugged by hand.
        'at': at.toIso8601String(),
      };

  factory ChatLine.fromJson(Map<String, dynamic> json) => ChatLine(
        from: _enumFrom(ChatFrom.values, json['from'], ChatFrom.peer),
        text: json['text'] as String? ?? '',
        at: DateTime.tryParse(json['at'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );

  @override
  bool operator ==(Object other) =>
      other is ChatLine &&
      other.from == from &&
      other.text == text &&
      other.at == at;

  @override
  int get hashCode => Object.hash(from, text, at);
}

/// One active session and everything said in it.
class SessionChat {
  const SessionChat({
    required this.id,
    required this.peerLabel,
    required this.direction,
    this.lines = const [],
    this.unread = 0,
  });

  /// The transport-specific identifier: an outgoing peer id or an incoming
  /// connection handle. Console selection and callbacks use [key] so opposite
  /// directions cannot collide.
  final String id;

  /// What the operator reads: a hostname or a user, falling back to the id.
  final String peerLabel;

  final SessionDirection direction;

  /// Console selection and send address. A peer id can equal an incoming
  /// connection id, so the transport id alone is not a session identity.
  String get key => '${direction.name}/$id';

  /// Oldest first, which is reading order. The client's own chat model keeps
  /// them newest first for its list view; the conversion happens at the window
  /// that owns the model, so nothing downstream has to know that.
  final List<ChatLine> lines;

  /// Messages arrived since the operator last looked at this session. Counted
  /// by the console, not by the window: the window has no idea which session
  /// the console is showing.
  final int unread;

  bool get isOutgoing => direction == SessionDirection.outgoing;

  SessionChat copyWith({List<ChatLine>? lines, int? unread}) => SessionChat(
        id: id,
        peerLabel: peerLabel,
        direction: direction,
        lines: lines ?? this.lines,
        unread: unread ?? this.unread,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'peerLabel': peerLabel,
        'direction': _nameOf(direction),
        'unread': unread,
        'lines': [for (final l in lines) l.toJson()],
      };

  factory SessionChat.fromJson(Map<String, dynamic> json) {
    final raw = json['lines'];
    return SessionChat(
      id: json['id'] as String? ?? '',
      peerLabel: json['peerLabel'] as String? ?? json['id'] as String? ?? '',
      direction: _enumFrom(
          SessionDirection.values, json['direction'], SessionDirection.outgoing),
      unread: json['unread'] is int ? json['unread'] as int : 0,
      lines: raw is List
          ? [
              for (final l in raw)
                if (l is Map) ChatLine.fromJson(Map<String, dynamic>.from(l))
            ]
          : const [],
    );
  }
}

/// A transcript as it travels on the window channel.
String encodeSessionChat(SessionChat chat) => jsonEncode(chat.toJson());

/// The other end of [encodeSessionChat]. Anything that is not a transcript —
/// a null from a window that has closed, a string that is not JSON — comes
/// back as null rather than throwing into a poll loop.
SessionChat? decodeSessionChat(Object? payload) {
  if (payload is! String || payload.isEmpty) return null;
  try {
    final json = jsonDecode(payload);
    if (json is! Map) return null;
    return SessionChat.fromJson(Map<String, dynamic>.from(json));
  } catch (_) {
    return null;
  }
}

/// Fold every window's answer into the one list the Sessions screen renders.
///
/// Answers arrive from several windows at once and in whatever order they came
/// back, so the order is imposed here: outgoing first, then by label, then by
/// id. Without it the list reshuffles itself on every poll. A session
/// answered for twice keeps the answer with more lines, which is the later of
/// the two.
List<SessionChat> mergeSessionChats(Iterable<SessionChat> chats) {
  final byKey = <String, SessionChat>{};
  for (final c in chats) {
    final key = c.key;
    final seen = byKey[key];
    if (seen == null || c.lines.length >= seen.lines.length) byKey[key] = c;
  }
  final out = byKey.values.toList();
  out.sort((a, b) {
    if (a.direction != b.direction) return a.isOutgoing ? -1 : 1;
    final byLabel = a.peerLabel.toLowerCase().compareTo(b.peerLabel.toLowerCase());
    return byLabel != 0 ? byLabel : a.id.compareTo(b.id);
  });
  return out;
}
