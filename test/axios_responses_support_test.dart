import 'dart:io';

import 'package:felorx_sdk_generator/src/axios_responses_support.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Axios stream decoder handles real UTF-8 chunks',
    () async {
      try {
        final result = await Process.run('node', ['--version']);
        final version = RegExp(
          r'^v(\d+)\.(\d+)',
        ).firstMatch('${result.stdout}');
        final major = int.tryParse(version?.group(1) ?? '') ?? 0;
        final minor = int.tryParse(version?.group(2) ?? '') ?? 0;
        if (result.exitCode != 0 || major < 22 || major == 22 && minor < 6) {
          markTestSkipped(
            'Node 22.6+ is required for native TypeScript checks',
          );
          return;
        }
      } on ProcessException {
        markTestSkipped('Node toolchain unavailable');
        return;
      }
      final output = await Directory.systemTemp.createTemp('felorx_ts_stream_');
      await File(
        '${output.path}/package.json',
      ).writeAsString('{"dependencies":{"axios":"^1.6.1"}}');
      await installAxiosResponsesSupport(
        configFile: 'configs/axios.json',
        outputDirectory: output.path,
      );
      await installAxiosResponsesSupport(
        configFile: 'configs/axios.json',
        outputDirectory: output.path,
      );
      expect(
        'responses_stream'
            .allMatches(await File('${output.path}/index.ts').readAsString())
            .length,
        1,
      );
      expect(await File('${output.path}/responses_http.ts').exists(), isTrue);
      expect(
        await File('${output.path}/package.json').readAsString(),
        contains('^1.20.0'),
      );
      expect(
        'responses_http'
            .allMatches(await File('${output.path}/index.ts').readAsString())
            .length,
        1,
      );
      await File(
        'test/fixtures/responses_stream_ts_check.mjs',
      ).copy('${output.path}/check.mjs');
      final result = await Process.run('node', [
        '--experimental-strip-types',
        'check.mjs',
      ], workingDirectory: output.path);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
