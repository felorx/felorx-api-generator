import 'dart:io';

import 'responses_sdk_scope_validator.dart';
import 'go_responses_support.dart';
import 'axios_responses_support.dart';

/// SDK 生成器
class SdkGenerator {
  final String openApiGeneratorJar;
  final String swaggerJsonPath;
  final String configPath;
  final String templateDirectory;
  final String outputDirectory;
  final String version;
  final String gitUserId;
  final String gitRepoId;
  final bool skipValidateSpec;

  SdkGenerator({
    required this.openApiGeneratorJar,
    required this.swaggerJsonPath,
    required this.configPath,
    required this.templateDirectory,
    required this.outputDirectory,
    required this.version,
    this.gitUserId = 'felorx',
    this.gitRepoId = 'felorx-api-dart',
    this.skipValidateSpec = true,
  });

  /// 生成 Dart SDK
  Future<void> generateDart() async {
    const scope = ResponsesSdkScopeValidator();
    scope.validateSpec(await File(swaggerJsonPath).readAsString());
    print('正在生成 Dart SDK...');

    // dart-dio resolves overrides relative to its library template root.
    // Passing the parent dart directory silently falls back to bundled files.
    final dioTemplates = Directory('$templateDirectory/libraries/dio');
    final effectiveTemplates = await dioTemplates.exists()
        ? dioTemplates.path
        : templateDirectory;

    final args = [
      '-jar',
      openApiGeneratorJar,
      'generate',
      '-g',
      'dart-dio',
      '-o',
      outputDirectory,
      '-c',
      configPath,
      '-t',
      effectiveTemplates,
      // Native JSON values preserve both branches of these wire unions.
      // dart-dio needs type mappings for fields and schema mappings to avoid
      // emitting empty, unusable composed model classes.
      '--type-mappings',
      'FelorxResponseInput=Object,FelorxResponseToolChoice=Object',
      '--schema-mappings',
      'FelorxResponseInput=Object,FelorxResponseToolChoice=Object',
      '--import-mappings',
      'FelorxResponseInput=dart:core,FelorxResponseToolChoice=dart:core',
      '-i',
      swaggerJsonPath,
      '--git-user-id',
      gitUserId,
      '--git-repo-id',
      gitRepoId,
      '--release-note',
      'update',
      '--artifact-version',
      version,
    ];

    if (skipValidateSpec) {
      args.add('--skip-validate-spec');
    }

    final process = await Process.start('java', args, runInShell: false);

    // 输出标准输出和标准错误
    await Future.wait([
      stdout.addStream(process.stdout),
      stderr.addStream(process.stderr),
    ]);

    final exitCode = await process.exitCode;

    if (exitCode != 0) {
      throw Exception('生成 Dart SDK 失败，退出码: $exitCode');
    }

    await scope.validateGeneratedDirectory(outputDirectory);
    print('Dart SDK 生成完成');
  }

  /// 生成其他语言的 SDK（如 Go、TypeScript 等）
  Future<void> generate({
    required String generator,
    required String outputDir,
    required String configFile,
    String? templateDir,
  }) async {
    const scope = ResponsesSdkScopeValidator();
    scope.validateSpec(await File(swaggerJsonPath).readAsString());
    print('正在生成 $generator SDK...');

    if (generator == 'typescript-axios' &&
        (templateDir == null || templateDir.isEmpty)) {
      final bundledTemplates = Directory(
        '${File(configFile).absolute.parent.parent.path}/templates/axios',
      );
      if (await bundledTemplates.exists()) templateDir = bundledTemplates.path;
    }

    final args = [
      '-jar',
      openApiGeneratorJar,
      'generate',
      '-g',
      generator,
      '-o',
      outputDir,
      '-c',
      configFile,
      '-i',
      swaggerJsonPath,
      '--git-user-id',
      gitUserId,
      '--git-repo-id',
      gitRepoId,
      '--release-note',
      'update',
      '--artifact-version',
      version,
    ];

    if (generator == 'typescript-axios') {
      args.addAll(['--additional-properties', 'npmVersion=$version']);
    }

    if (templateDir != null && templateDir.isNotEmpty) {
      args.addAll(['-t', templateDir]);
    }

    if (skipValidateSpec) {
      args.add('--skip-validate-spec');
    }

    final process = await Process.start('java', args, runInShell: false);

    await Future.wait([
      stdout.addStream(process.stdout),
      stderr.addStream(process.stderr),
    ]);

    final exitCode = await process.exitCode;

    if (exitCode != 0) {
      throw Exception('生成 $generator SDK 失败，退出码: $exitCode');
    }

    if (generator == 'go') {
      await installGoResponsesSupport(
        configFile: configFile,
        outputDirectory: outputDir,
      );
    }
    if (generator == 'typescript-axios') {
      await installAxiosResponsesSupport(
        configFile: configFile,
        outputDirectory: outputDir,
      );
    }
    await scope.validateGeneratedDirectory(outputDir);
    print('$generator SDK 生成完成');
  }
}
