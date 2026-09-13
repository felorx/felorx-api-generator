import 'dart:convert';
import 'dart:io';

import 'package:felorx_sdk_generator/src/generator.dart';
import 'package:felorx_sdk_generator/src/responses_sdk_scope_validator.dart';
import 'package:test/test.dart';

import 'responses_sdk_scope_validator_test.dart' show coreSpec;

void main() {
  final enabled = Platform.environment['FELORX_SDK_GENERATOR_LIVE'] == '1';
  final exported = Platform.environment['FELORX_EXPORTED_SWAGGER'];
  final compile = Platform.environment['FELORX_SDK_COMPILE'] == '1';
  final keep = Platform.environment['FELORX_SDK_KEEP_OUTPUT'] == '1';
  for (final language in ['dart', 'go', 'axios']) {
    test(
      'real generator preserves Responses scope for $language',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'felorx_sdk_generated_',
        );
        if (keep) {
          print('Retained $language SDK: ${root.path}');
        } else {
          addTearDown(() => root.delete(recursive: true));
        }
        final spec =
            jsonDecode(
                  exported == null
                      ? jsonEncode(coreSpec())
                      : await File(exported).readAsString(),
                )
                as Map<String, dynamic>;
        for (final entry in (spec['paths'] as Map<String, Object?>).entries) {
          if (entry.key.contains('{response_id}')) {
            (entry.value as Map<String, Object?>)['parameters'] = [
              {
                'name': 'response_id',
                'in': 'path',
                'required': true,
                'schema': {'type': 'string'},
              },
            ];
          }
        }
        final specification = File('${root.path}/spec.json');
        await specification.writeAsString(jsonEncode(spec));
        final output = '${root.path}/sdk';
        final generator = SdkGenerator(
          openApiGeneratorJar: File('openapi-generator-cli.jar').absolute.path,
          swaggerJsonPath: specification.path,
          configPath: File('configs/dart.json').absolute.path,
          templateDirectory: Directory('templates/dart').absolute.path,
          outputDirectory: output,
          version: '0.0.0-scope-test',
          skipValidateSpec: false,
        );
        if (language == 'dart') {
          await generator.generateDart();
        } else {
          await generator.generate(
            generator: language == 'axios' ? 'typescript-axios' : 'go',
            outputDir: output,
            configFile: File('configs/$language.json').absolute.path,
          );
        }
        await const ResponsesSdkScopeValidator().validateGeneratedDirectory(
          output,
        );
        // Inspect actual generated implementation files, not documentation or
        // manifests, for every core operation's public method.
        final sources = await Directory(output)
            .list(recursive: true)
            .where(
              (file) =>
                  file is File &&
                  (file.path.endsWith('.dart') ||
                      file.path.endsWith('.go') ||
                      file.path.endsWith('.ts')),
            )
            .cast<File>()
            .asyncMap((file) => file.readAsString())
            .join('\n');
        final normalized = sources
            .replaceAll(RegExp('[^a-zA-Z0-9]'), '')
            .toLowerCase();
        for (final operation in [
          'createResponse',
          'retrieveResponse',
          'deleteResponse',
          'cancelResponse',
          exported == null ? 'listInputItems' : 'listResponseInputItems',
          'compactResponse',
          exported == null ? 'countInputTokens' : 'countResponseInputTokens',
        ]) {
          expect(normalized, contains(operation.toLowerCase()));
        }
        if (compile) {
          Future<void> run(String command, List<String> arguments) async {
            final result = await Process.run(
              command,
              arguments,
              workingDirectory: output,
              runInShell: Platform.isWindows,
            );
            final detail = '${result.stdout}\n${result.stderr}';
            expect(
              result.exitCode,
              0,
              reason:
                  '$language: $command ${arguments.join(' ')}\n'
                  '${detail.length > 10000 ? detail.substring(0, 10000) : detail}',
            );
          }

          switch (language) {
            case 'dart':
              if ((await File(
                '$output/pubspec.yaml',
              ).readAsString()).contains('resolution: workspace')) {
                await File('${root.path}/pubspec.yaml').writeAsString(
                  "name: sdk_compile_fixture\nenvironment:\n  sdk: '>=3.8.0 <4.0.0'\nworkspace:\n  - sdk\n",
                );
              }
              await run('dart', ['pub', 'get']);
              await run('dart', [
                'run',
                'build_runner',
                'build',
                '--delete-conflicting-outputs',
              ]);
              await run('dart', ['analyze', '--no-fatal-warnings', 'lib']);
              if (exported != null) {
                await File('$output/wire_check.dart').writeAsString(
                  await File(
                    'test/fixtures/responses_wire_check.dart.txt',
                  ).readAsString(),
                );
                await run('dart', ['run', 'wire_check.dart']);
                await File('$output/stream_check.dart').writeAsString(
                  await File(
                    'test/fixtures/responses_stream_check.dart.txt',
                  ).readAsString(),
                );
                await run('dart', ['run', 'stream_check.dart']);
              }
            case 'go':
              await run('go', ['mod', 'tidy']);
              await run('go', ['test', '-run', '^\$', './...']);
              await File(
                'test/fixtures/responses_stream_client_go_test.go.txt',
              ).copy('$output/responses_stream_client_test.go');
              await run('go', [
                'test',
                '-count=1',
                '-timeout=30s',
                '-run',
                '^TestFelorxResponseStreamClient\$',
                './...',
              ]);
            case 'axios':
              final package =
                  jsonDecode(await File('$output/package.json').readAsString())
                      as Map<String, dynamic>;
              expect(package['version'], '0.0.0-scope-test');
              if (exported != null) {
                expect(
                  await File('$output/responses_client.ts').exists(),
                  isTrue,
                  reason:
                      'Full Host contract must produce the Responses class adapter',
                );
              }
              await run('npm', [
                'install',
                '--ignore-scripts',
                '--no-audit',
                '--no-fund',
              ]);
              await run('npx', ['--no-install', 'tsc', '--noEmit']);
              await run('npx', ['--no-install', 'tsc']);
              await File(
                'test/fixtures/responses_http_ts_check.cjs',
              ).copy('$output/responses_http_ts_check.cjs');
              await run('node', ['responses_http_ts_check.cjs']);
          }
        }
      },
      skip: !enabled,
      timeout: const Timeout(Duration(minutes: 10)),
    );
  }
}
