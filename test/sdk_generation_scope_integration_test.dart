import 'dart:convert';
import 'dart:io';
import 'package:felorx_sdk_generator/src/generator.dart';
import 'package:felorx_sdk_generator/src/platform_sdk_scope_validator.dart';
import 'package:test/test.dart';

void main() {
  final enabled = Platform.environment['FELORX_SDK_GENERATOR_LIVE'] == '1';
  final exported = Platform.environment['FELORX_EXPORTED_SWAGGER'];
  for (final language in ['dart', 'go', 'axios']) {
    test(
      '实际 $language 生成器只生成平台契约',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'felorx_platform_sdk_',
        );
        addTearDown(() => root.delete(recursive: true));
        final source = exported == null
            ? jsonEncode({
                'openapi': '3.0.1',
                'info': {'title': 'platform', 'version': '1.0.0'},
                'paths': {
                  '/api/apps': {
                    'get': {
                      'operationId': 'getApps',
                      'responses': {
                        '200': {'description': 'OK'},
                      },
                    },
                  },
                },
              })
            : await File(exported).readAsString();
        const PlatformSdkScopeValidator().validateSpec(source);
        final spec = File('${root.path}/spec.json');
        await spec.writeAsString(source);
        final output = '${root.path}/sdk';
        final generator = SdkGenerator(
          openApiGeneratorJar: File('openapi-generator-cli.jar').absolute.path,
          swaggerJsonPath: spec.path,
          configPath: File('configs/dart.json').absolute.path,
          templateDirectory: Directory('templates/dart').absolute.path,
          outputDirectory: output,
          version: '1.0.0',
        );
        if (language == 'dart') {
          await generator.generateDart();
        } else {
          await generator.generate(
            generator: language == 'go' ? 'go' : 'typescript-axios',
            outputDir: output,
            configFile: File('configs/$language.json').absolute.path,
          );
        }
        final files = await Directory(output)
            .list(recursive: true)
            .where(
              (f) =>
                  f is File &&
                  (f.path.endsWith('.dart') ||
                      f.path.endsWith('.go') ||
                      f.path.endsWith('.ts')),
            )
            .cast<File>()
            .toList();
        final sources = (await Future.wait(
          files.map((f) => f.readAsString()),
        )).join('\n');
        expect(sources, isNot(contains('/api/ai/')));
        expect(sources, isNot(contains('class ResponsesApi')));
        expect(sources, contains('/api/'));
      },
      skip: enabled ? false : '设置 FELORX_SDK_GENERATOR_LIVE=1 执行真实生成',
    );
  }
}
