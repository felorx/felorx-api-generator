import 'dart:io';

import 'package:felorx_sdk_generator/src/go_responses_support.dart';
import 'package:test/test.dart';

void main() {
  test(
    'bundled Go stream support compiles and handles real pipes',
    () async {
      try {
        final version = await Process.run('go', ['version']);
        if (version.exitCode != 0) {
          markTestSkipped('Go toolchain unavailable');
          return;
        }
      } on ProcessException {
        markTestSkipped('Go toolchain unavailable');
        return;
      }
      final output = await Directory.systemTemp.createTemp('felorx_go_stream_');
      await installGoResponsesSupport(
        configFile: 'configs/go.json',
        outputDirectory: output.path,
        includeClientAdapter: false,
      );
      await File(
        '${output.path}/go.mod',
      ).writeAsString('module felorx_stream_test\n\ngo 1.20\n');
      await File(
        'test/fixtures/responses_stream_go_test.go.txt',
      ).copy('${output.path}/responses_stream_test.go');
      final result = await Process.run(
        'go',
        ['test', '-count=1', '-timeout=20s', './...'],
        workingDirectory: output.path,
        environment: {'GOWORK': 'off'},
      );
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
