import 'package:test/test.dart';
import 'package:felorx_sdk_generator/src/platform_sdk_scope_validator.dart';

void main() {
  test('平台 Swagger 不需要 Responses 能力', () {
    const PlatformSdkScopeValidator().validateSpec(
      '{"paths":{"/api/apps":{}}}',
    );
  });
  test('拒绝把旧 AI 推理和管理接口带回平台 SDK', () {
    for (final path in [
      '/api/ai/providers',
      '/api/ai/v1/responses',
      '/api/ai/usage',
    ]) {
      expect(
        () => const PlatformSdkScopeValidator().validateSpec(
          '{"paths":{"$path":{}}}',
        ),
        throwsStateError,
      );
    }
  });
}
