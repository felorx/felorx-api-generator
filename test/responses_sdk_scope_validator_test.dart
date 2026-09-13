import 'dart:convert';
import 'dart:io';

import 'package:felorx_sdk_generator/src/generator.dart';
import 'package:felorx_sdk_generator/src/responses_sdk_scope_validator.dart';
import 'package:test/test.dart';

void main() {
  const validator = ResponsesSdkScopeValidator();
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('felorx_sdk_scope_');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test(
    'accepts the seven core operations and unrelated application file APIs',
    () {
      final spec = coreSpec();
      (spec['paths'] as Map)['/api/app/files'] = {'get': {}};
      validator.validateSpec(jsonEncode(spec));
    },
  );

  test(
    'rejects missing canonical operations rather than accepting legacy aliases',
    () {
      final spec = coreSpec();
      final paths = spec['paths'] as Map<String, Object?>;
      paths['/api/ai/openai/responses'] = paths.remove('/api/ai/v1/responses');
      expect(
        () => validator.validateSpec(jsonEncode(spec)),
        throwsA(isA<StateError>()),
      );
    },
  );

  test('rejects resource paths and resource schemas before generation', () {
    for (final path in [
      '/api/ai/v1/files',
      '/api/ai/openai/vector_stores/{id}',
      '/files/{id}',
    ]) {
      final spec = coreSpec();
      (spec['paths'] as Map)[path] = {'get': {}};
      expect(
        () => validator.validateSpec(jsonEncode(spec)),
        throwsA(isA<StateError>()),
      );
    }
    final spec = coreSpec()
      ..['components'] = {
        'schemas': {'OpenAiFileSearchTool': {}},
      };
    expect(
      () => validator.validateSpec(jsonEncode(spec)),
      throwsA(isA<StateError>()),
    );
  });

  test('rejects generated File Search and Vector Store resources', () async {
    for (final entry in <String, String>{
      'tool.dart': "enum Tool { @JsonValue('file_search') fileSearch }",
      'client.ts': "const path = '/api/ai/v1/vector_stores';",
      'model.go': 'type VectorStoreObject struct {}',
      'client.py': 'class OpenAiFilesApi: pass',
    }.entries) {
      final file = File('${directory.path}/${entry.key}');
      await file.writeAsString(entry.value);
      await expectLater(
        validator.validateGeneratedDirectory(directory.path),
        throwsA(isA<StateError>()),
      );
      await file.delete();
    }
  });

  test(
    'rejects stale resource files even if their contents are empty',
    () async {
      await File('${directory.path}/model_vector_store.go').writeAsString('');
      await expectLater(
        validator.validateGeneratedDirectory(directory.path),
        throwsA(isA<StateError>()),
      );
    },
  );

  test(
    'rejects stale resource documentation as well as implementation',
    () async {
      await File(
        '${directory.path}/VectorStoreApi.md',
      ).writeAsString('Old resource API');
      await expectLater(
        validator.validateGeneratedDirectory(directory.path),
        throwsA(isA<StateError>()),
      );
    },
  );

  test(
    'keeps local file input and ordinary application storage clients',
    () async {
      await File(
        '${directory.path}/files.dart',
      ).writeAsString("class FileDto {}\nconst path = '/api/app/files';");
      await File(
        '${directory.path}/response_input_file.ts',
      ).writeAsString('interface ResponseInputFile { file_data: string }');
      await validator.validateGeneratedDirectory(directory.path);
    },
  );

  test(
    'does not scan dependencies and rejects empty generated outputs',
    () async {
      await expectLater(
        validator.validateGeneratedDirectory(directory.path),
        throwsA(isA<StateError>()),
      );
      final dependency = Directory('${directory.path}/node_modules/provider');
      await dependency.create(recursive: true);
      await File(
        '${dependency.path}/file_search.ts',
      ).writeAsString("type Tool = 'file_search';");
      await File(
        '${directory.path}/client.ts',
      ).writeAsString('export class ResponsesApi {}');
      await validator.validateGeneratedDirectory(directory.path);
    },
  );

  test(
    'both generation entry points reject incomplete specs before modifying outputs',
    () async {
      final specFile = File('${directory.path}/spec.json');
      await specFile.writeAsString('{"openapi":"3.0.3","paths":{}}');
      final sentinel = File('${directory.path}/keep.txt');
      await sentinel.writeAsString('existing SDK');
      final generator = SdkGenerator(
        openApiGeneratorJar: 'must-not-start.jar',
        swaggerJsonPath: specFile.path,
        configPath: 'unused',
        templateDirectory: 'unused',
        outputDirectory: directory.path,
        version: 'test',
      );
      await expectLater(generator.generateDart(), throwsA(isA<StateError>()));
      await expectLater(
        generator.generate(
          generator: 'go',
          outputDir: directory.path,
          configFile: 'unused',
        ),
        throwsA(isA<StateError>()),
      );
      expect(await sentinel.readAsString(), 'existing SDK');
      expect(await directory.list().length, 2);
    },
  );
}

Map<String, Object?> coreSpec() => {
  'openapi': '3.0.3',
  'info': {'title': 'Felorx Responses scope fixture', 'version': '1.0.0'},
  'paths': <String, Object?>{
    '/api/ai/v1/responses': {'post': operation('createResponse')},
    '/api/ai/v1/responses/{response_id}': {
      'get': operation('retrieveResponse'),
      'delete': operation('deleteResponse'),
    },
    '/api/ai/v1/responses/{response_id}/cancel': {
      'post': operation('cancelResponse'),
    },
    '/api/ai/v1/responses/{response_id}/input_items': {
      'get': operation('listInputItems'),
    },
    '/api/ai/v1/responses/compact': {'post': operation('compactResponse')},
    '/api/ai/v1/responses/input_tokens': {
      'post': operation('countInputTokens'),
    },
  },
};

Map<String, Object?> operation(String id) => {
  'operationId': id,
  'responses': {
    '200': {'description': 'OK'},
  },
};
