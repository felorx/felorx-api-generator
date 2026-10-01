import 'dart:io';
import 'package:felorx_sdk_generator/src/platform_sdk_scope_validator.dart';
import 'package:test/test.dart';

void main() {
  final path = Platform.environment['FELORX_EXPORTED_SWAGGER'];
  test(
    'Host 导出的平台契约不再暴露 AI 接口',
    () {
      const PlatformSdkScopeValidator().validateSpec(
        File(path!).readAsStringSync(),
      );
    },
    skip: path == null ? '设置 FELORX_EXPORTED_SWAGGER 验证 Host 导出' : false,
  );
}
