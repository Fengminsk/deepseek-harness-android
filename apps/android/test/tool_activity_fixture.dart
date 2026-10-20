import 'dart:convert';

import 'package:dsh_android/runtime.dart';

Json toolEvent(int seq, String type, Json data, {dynamic surfaceOp}) => {
  'seq': seq,
  'time': seq * 1000,
  'type': type,
  'data': data,
  'surfaceOp': ?surfaceOp,
};

Json callEvent(
  int seq, {
  String id = 'call-0',
  String name = 'android_shell',
  int turn = 1,
  int step = 1,
  Json args = const {'command': 'pwd'},
}) => toolEvent(seq, 'tool/call', {
  'turn': turn,
  'step': step,
  'callId': id,
  'name': name,
  'arguments': jsonEncode(args),
});

Json resultEvent(
  int seq, {
  String id = 'call-0',
  int turn = 1,
  int step = 1,
  String text = 'done',
  bool isError = false,
  Json? error,
  dynamic meta,
  dynamic surfaceOp = 'append',
}) => toolEvent(seq, 'tool/result', {
  'turn': turn,
  'step': step,
  'message': {
    'role': 'tool',
    'source': {'kind': 'tool', 'callId': id},
    // Deliberately different: source.callId owns pairing, not this legacy id.
    'toolCallId': 'legacy-other-id',
    'content': [
      {'type': 'text', 'text': text},
    ],
    if (isError) 'isError': true,
  },
  'error': ?error,
  'meta': ?meta,
}, surfaceOp: surfaceOp);

Json dispatchEvent(
  int seq, {
  String root = 'call-0',
  String? parent,
  String child = 'sub-a',
  bool end = false,
  String text = 'child result',
  String name = 'read',
}) => toolEvent(seq, end ? 'tool/ptc-dispatch' : 'tool/ptc-dispatch-start', {
  'rootCallId': root,
  'parentCallId': parent ?? root,
  'subCallId': child,
  'name': name,
  'arguments': {'file_path': '/workspace/a.txt'},
  if (end) ...{
    'isError': false,
    'content': [
      {'type': 'text', 'text': text},
    ],
  },
});
