import 'dart:convert';

/// 平台 SDK 不承载独立 AI 网关的推理或管理协议。
class PlatformSdkScopeValidator {
  const PlatformSdkScopeValidator();
  void validateSpec(String source) {
    final document = jsonDecode(source);
    if (document is! Map || document['paths'] is! Map)
      throw StateError('SDK specification has no paths');
    for (final path in (document['paths'] as Map).keys) {
      if (path.toString().startsWith('/api/ai/')) {
        throw StateError('平台 SDK 不能包含已移除的 AI 接口：$path');
      }
    }
  }
}
