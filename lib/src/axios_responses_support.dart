import 'dart:io';
import 'dart:convert';

Future<void> installAxiosResponsesSupport({
  required String configFile,
  required String outputDirectory,
}) async {
  final source = File(
    '${File(configFile).absolute.parent.parent.path}/templates/axios/responses_stream.ts.txt',
  );
  await source.copy('$outputDirectory/responses_stream.ts');
  await File(
    '${source.parent.path}/responses_http.ts.txt',
  ).copy('$outputDirectory/responses_http.ts');
  final api = File('$outputDirectory/api.ts');
  final apiText = await api.exists() ? await api.readAsString() : '';
  final hasResponsesClient =
      apiText.contains('export class ResponsesApi ') &&
      apiText.contains('FelorxResponsesCreateRequest') &&
      apiText.contains('createResponseLegacy:');
  if (hasResponsesClient) {
    await File(
      '${source.parent.path}/responses_client.ts.txt',
    ).copy('$outputDirectory/responses_client.ts');
  }
  final manifest = File('$outputDirectory/package.json');
  if (await manifest.exists()) {
    final package =
        jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
    // Generated declarations built with Axios 1.20 use its response generics;
    // older installs silently lose types when consumers use skipLibCheck.
    (package['dependencies'] as Map<String, dynamic>)['axios'] = '^1.20.0';
    await manifest.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(package)}\n',
    );
  }
  final index = File('$outputDirectory/index.ts');
  final existing = await index.exists() ? await index.readAsString() : '';
  const export = "export * from './responses_stream';";
  if (!existing.contains(export)) {
    await index.writeAsString('$existing\n$export\n');
  }
  const httpExport = "export * from './responses_http';";
  final updated = await index.readAsString();
  if (!updated.contains(httpExport)) {
    await index.writeAsString('$updated\n$httpExport\n');
  }
  const clientExport = "export * from './responses_client';";
  final withHttp = await index.readAsString();
  if (hasResponsesClient && !withHttp.contains(clientExport)) {
    await index.writeAsString('$withHttp\n$clientExport\n');
  }
}
