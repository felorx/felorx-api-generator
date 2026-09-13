import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Gate the input contract and generated source, including stale files left by
/// OpenAPI Generator. Generic application file/storage APIs remain in scope.
class ResponsesSdkScopeValidator {
  const ResponsesSdkScopeValidator();

  static const _forbiddenResourceMarkers = ['file_search', 'vector_store'];
  static const _coreOperations = {
    'post /api/ai/v1/responses',
    'get /api/ai/v1/responses/{response_id}',
    'delete /api/ai/v1/responses/{response_id}',
    'post /api/ai/v1/responses/{response_id}/cancel',
    'get /api/ai/v1/responses/{response_id}/input_items',
    'post /api/ai/v1/responses/compact',
    'post /api/ai/v1/responses/input_tokens',
  };
  static const _methods = {
    'get',
    'post',
    'put',
    'patch',
    'delete',
    'head',
    'options',
    'trace',
  };
  static const _ignoredDirectories = {
    '.git',
    '.dart_tool',
    'node_modules',
    'vendor',
    'build',
    '.openapi-generator',
  };
  static const _sourceExtensions = {
    '.dart',
    '.ts',
    '.tsx',
    '.go',
    '.py',
    '.java',
    '.cs',
  };

  void validateSpec(String source) {
    final document = jsonDecode(source);
    if (document is! Map || document['paths'] is! Map) {
      throw StateError('SDK specification has no paths');
    }
    final found = <String>{};
    for (final entry in (document['paths'] as Map).entries) {
      final path = entry.key.toString().replaceAll(
        RegExp(r'\{[^}]+\}'),
        '{response_id}',
      );
      if (_resourcePath(path)) {
        throw StateError(
          'SDK specification includes unsupported AI resource: $path',
        );
      }
      if (entry.value is! Map) continue;
      for (final method in (entry.value as Map).keys.map(
        (key) => key.toString().toLowerCase(),
      )) {
        if (!_methods.contains(method)) continue;
        final operation = '$method $path';
        final canonical = operation.replaceFirst(
          '/api/ai/openai/',
          '/api/ai/v1/',
        );
        if (path.startsWith('/api/ai/v1/responses') ||
            path.startsWith('/api/ai/openai/responses')) {
          if (!_coreOperations.contains(canonical)) {
            throw StateError(
              'SDK specification includes an unsupported Responses operation: $operation',
            );
          }
          // Legacy aliases do not substitute for the canonical contract.
          if (_coreOperations.contains(operation)) found.add(operation);
        }
      }
    }
    final schemas = (document['components'] as Map?)?['schemas'];
    if (schemas is Map) {
      for (final name in schemas.keys) {
        if (_resourceSymbol(name.toString())) {
          throw StateError(
            'SDK specification includes an unsupported resource schema: $name',
          );
        }
      }
    }
    final missing = _coreOperations.difference(found);
    if (missing.isNotEmpty) {
      throw StateError(
        'SDK specification is missing Responses core operations: ${missing.join(', ')}',
      );
    }
  }

  Future<void> validateGeneratedDirectory(String directory) async {
    final root = Directory(directory);
    if (!await root.exists())
      throw StateError('Generated SDK directory is missing');
    var sourceCount = 0;
    Future<void> visit(Directory current) async {
      await for (final entry in current.list(followLinks: false)) {
        if (entry is Directory) {
          if (!_ignoredDirectories.contains(p.basename(entry.path)))
            await visit(entry);
        } else if (entry is Link) {
          // Generated source must be inspected in this directory, not hidden
          // behind links to an unvalidated tree.
          if (!_ignoredDirectories.contains(p.basename(entry.path))) {
            throw StateError(
              'Generated SDK contains an unvalidated symbolic link: ${p.relative(entry.path, from: directory)}',
            );
          }
        } else if (entry is File) {
          final relative = p.relative(entry.path, from: directory);
          if (_resourceSymbol(p.basenameWithoutExtension(entry.path))) {
            throw StateError(
              'generated SDK reintroduced unsupported resource: $relative',
            );
          }
          if (!_sourceExtensions.contains(p.extension(entry.path))) continue;
          sourceCount++;
          final source = await entry.readAsString();
          if (_resourcePath(source) ||
              _forbiddenResourceMarkers.any(
                (marker) => RegExp(
                  '[\'\"]${RegExp.escape(marker)}s?[\'\"]',
                ).hasMatch(source),
              ) ||
              RegExp(
                    r'\b(?:class|interface|enum|type)\s+([A-Za-z_][A-Za-z_0-9]*)',
                  )
                  .allMatches(source)
                  .any((match) => _resourceSymbol(match.group(1)!))) {
            throw StateError(
              'generated SDK reintroduced unsupported resource: $relative',
            );
          }
        }
      }
    }

    await visit(root);
    if (sourceCount == 0) throw StateError('Generated SDK has no source files');
  }

  static bool _resourceSymbol(String name) {
    final normalized = name
        .replaceAll(RegExp('[^a-zA-Z0-9]'), '')
        .toLowerCase();
    return normalized.contains('filesearch') ||
        normalized.contains('vectorstore') ||
        normalized.startsWith('openaifile');
  }

  static bool _resourcePath(String value) => RegExp(
    r'(?:^|[\x27"\s(])/(?:api/ai/(?:v1|openai)/)?(?:files|vector_stores)(?:[/\x27"?{}\s]|$)',
    caseSensitive: false,
  ).hasMatch(value);
}
