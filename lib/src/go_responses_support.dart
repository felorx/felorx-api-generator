import 'dart:convert';
import 'dart:io';

/// Installs the bundled native Responses stream reader after Go generation.
Future<void> installGoResponsesSupport({
  required String configFile,
  required String outputDirectory,
  bool includeClientAdapter = true,
}) async {
  final config = jsonDecode(await File(configFile).readAsString());
  final packageName = config['packageName'] ?? 'openapi';
  if (packageName is! String ||
      !RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(packageName)) {
    throw const FormatException('Invalid Go packageName');
  }
  for (final name in [
    'responses_stream',
    if (includeClientAdapter) 'responses_stream_client',
  ]) {
    final template = File(
      '${File(configFile).absolute.parent.parent.path}/templates/go/$name.go.tmpl',
    );
    final source = (await template.readAsString()).replaceAll(
      '{{packageName}}',
      packageName,
    );
    await File('$outputDirectory/$name.go').writeAsString(source);
  }
}
