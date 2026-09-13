import 'dart:convert';
import 'dart:io';

import 'package:felorx_sdk_generator/src/responses_sdk_scope_validator.dart';
import 'package:test/test.dart';

void main() {
  final path = Platform.environment['FELORX_EXPORTED_SWAGGER'];
  final generatedPath = Platform.environment['FELORX_GENERATED_SDK_PATH'];
  test(
    'installed SDK retains the supported Responses scope',
    () async {
      await const ResponsesSdkScopeValidator().validateGeneratedDirectory(
        generatedPath!,
      );
    },
    skip: generatedPath == null
        ? 'Set FELORX_GENERATED_SDK_PATH to the installed SDK'
        : false,
  );
  test(
    'actual exported Responses contract contains complete SDK inputs',
    () {
      final source = File(path!).readAsStringSync();
      const ResponsesSdkScopeValidator().validateSpec(source);
      final spec = jsonDecode(source) as Map<String, dynamic>;
      final paths = spec['paths'] as Map<String, dynamic>;
      final schemas = spec['components']['schemas'] as Map<String, dynamic>;
      expect(
        spec['components']['securitySchemes']['FelorxBearer']['scheme'],
        'bearer',
      );
      final ids = <String>{};
      final allIds = <String>{};
      for (final path in paths.values) {
        for (final method in (path as Map).entries) {
          if (![
            'get',
            'post',
            'put',
            'patch',
            'delete',
            'head',
            'options',
            'trace',
          ].contains(method.key))
            continue;
          expect(
            allIds.add((method.value['operationId'] as String).toLowerCase()),
            isTrue,
            reason: 'Ambiguous operation ID: ${method.value['operationId']}',
          );
        }
      }
      var operations = 0;
      for (final entry in paths.entries) {
        if (!entry.key.startsWith('/api/ai/v1/responses') &&
            !entry.key.startsWith('/api/ai/openai/responses'))
          continue;
        for (final method in (entry.value as Map).entries) {
          if (!['get', 'post', 'delete'].contains(method.key)) continue;
          final operation = method.value as Map;
          expect(
            (operation['security'] as List).any(
              (dynamic entry) => entry.containsKey('FelorxBearer'),
            ),
            isTrue,
          );
          expect(ids.add(operation['operationId'] as String), isTrue);
          expect(
            (operation['parameters'] as List).any(
              (dynamic p) =>
                  p['in'] == 'header' && p['name'] == 'X-Felorx-Ai-Provider',
            ),
            isTrue,
          );
          final success = operation['responses']['200']['content'] as Map;
          expect(success['application/json']['schema'][r'$ref'], isNotNull);
          if ([
            'createResponse',
            'compactResponse',
            'countResponseInputTokens',
          ].any((id) => (operation['operationId'] as String).startsWith(id))) {
            expect(operation['requestBody']['required'], isTrue);
            expect(
              operation['requestBody']['content']['application/json']['schema'][r'$ref'],
              isNotNull,
            );
          }
          operations++;
        }
      }
      expect(operations, 14);
      expect(
        paths['/api/ai/v1/responses']['post']['x-felorx-responses-stream'],
        isTrue,
      );
      expect(
        paths['/api/ai/openai/responses']['post']['x-felorx-responses-stream'],
        isTrue,
      );
      void checkRefs(dynamic value) {
        if (value is Map) {
          final ref = value[r'$ref'];
          if (ref is String && ref.startsWith('#/components/schemas/')) {
            expect(
              schemas.containsKey(
                ref.substring('#/components/schemas/'.length),
              ),
              isTrue,
              reason: 'Unresolved schema: $ref',
            );
          }
          value.values.forEach(checkRefs);
        } else if (value is List) {
          value.forEach(checkRefs);
        }
      }

      checkRefs(spec);
      expect(
        paths['/api/ai/v1/responses']['post']['responses']['200']['content']['text/event-stream'],
        isNotNull,
      );
    },
    skip: path == null
        ? 'Set FELORX_EXPORTED_SWAGGER to a real Host export'
        : false,
  );
}
