import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../scripts/generate-desktop-notices.dart' as notices;

void main() {
  late Directory temporary;
  late Directory standards;
  late Directory root;
  setUp(() {
    root = Directory.current.parent;
    temporary = Directory.systemTemp.createTempSync('desktop-licenses-');
    standards = Directory.fromUri(temporary.uri.resolve('standards/'))
      ..createSync();
  });
  tearDown(() => temporary.deleteSync(recursive: true));

  Map<String, dynamic> package(
    String name, {
    String? license = 'MIT',
    String? licenseFile,
    Map<String, String> files = const {},
    String version = '1.0.0',
    bool macro = false,
  }) {
    final directory = Directory.fromUri(
      temporary.uri.resolve('$name-$version/'),
    )..createSync();
    for (final entry in files.entries) {
      File.fromUri(directory.uri.resolve(entry.key))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(entry.value);
    }
    return {
      'id': '$name-$version',
      'name': name,
      'version': version,
      'license': license,
      'license_file': licenseFile,
      'manifest_path': '${directory.path}/Cargo.toml',
      'authors': ['Author of $name'],
      'repository': 'https://example.com/$name',
      'targets': [
        {
          'kind': [macro ? 'proc-macro' : 'lib'],
        },
      ],
    };
  }

  Map<String, dynamic> metadata(List<Map<String, dynamic>> packages) => {
    'packages': [package('root'), ...packages],
    'resolve': {
      'root': 'root-1.0.0',
      'nodes': [
        {
          'id': 'root-1.0.0',
          'deps': [
            for (final p in packages)
              {
                'pkg': p['id'],
                'dep_kinds': [
                  <String, dynamic>{'kind': null},
                ],
              },
          ],
        },
        for (final p in packages) {'id': p['id'], 'deps': []},
      ],
    },
  };

  String render(Map<String, dynamic> graph) => notices
      .rustLicenseDocument(graph, standards, target: 'x86_64-pc-windows-msvc')
      .text;

  test(
    'includes all license files and explicit Cargo license_file verbatim',
    () {
      final text = render(
        metadata([
          package(
            'licensed',
            licenseFile: 'legal/terms.txt',
            files: {
              'license-MIT': 'Copyright Alice\r\nMIT terms\r\n',
              'legal/COPYING.extra': 'Copy terms\n',
              'legal/terms.txt': 'Explicit terms\n',
              'Notice': 'Attribution\n',
              'LiCeNcE.txt': 'Licence spelling\n',
              'UNLICENSE': 'Public domain\n',
              'unrelated.txt': 'Must not be copied',
            },
          ),
        ]),
      );
      expect(text, contains('Copyright Alice\nMIT terms\n'));
      for (final filename in [
        'license-MIT',
        'legal/COPYING.extra',
        'legal/terms.txt',
        'Notice',
        'LiCeNcE.txt',
        'UNLICENSE',
      ]) {
        expect(text, contains('--- $filename ---'));
      }
      expect(text, isNot(contains('Must not be copied')));
      expect(text, isNot(contains('\r')));
    },
  );

  test('dual license preserves the expression and both files', () {
    final text = render(
      metadata([
        package(
          'dual',
          license: 'MIT OR Apache-2.0',
          files: {
            'LICENSE-MIT': 'MIT with Copyright Alice',
            'LICENSE-APACHE': 'Apache with Copyright Bob',
          },
        ),
      ]),
    );
    expect(text, contains('Cargo license: MIT OR Apache-2.0'));
    expect(text, contains('MIT with Copyright Alice'));
    expect(text, contains('Apache with Copyright Bob'));
  });

  test('missing files use every SPDX term including slash expressions', () {
    File.fromUri(standards.uri.resolve('MIT.txt'))
        .writeAsStringSync('MIT standard');
    File.fromUri(standards.uri.resolve('Apache-2.0.txt'))
        .writeAsStringSync('Apache standard');
    final document = notices.rustLicenseDocument(
      metadata([package('fallback', license: 'Apache-2.0/MIT')]),
      standards,
      target: 'aarch64-apple-darwin',
    );
    expect(document.standardPackages, ['fallback 1.0.0']);
    expect(document.text, contains('Cargo license: Apache-2.0/MIT'));
    expect(document.text, contains('包内未附许可文件，以下为 SPDX 标准文本'));
    expect(document.text, contains('Author of fallback'));
    expect(document.text, contains('https://example.com/fallback'));
    expect(document.text, contains('MIT standard'));
    expect(document.text, contains('Apache standard'));
  });

  test(
    'unknown licenses and missing standard texts list every failing package',
    () {
      final graph = metadata([
        package(
          'unknown',
          license: 'LicenseRef-Unknown',
          files: {'LICENSE': 'text'},
        ),
        package('missing', license: 'MIT'),
      ]);
      expect(
        () => render(graph),
        throwsA(
          isA<StateError>()
              .having((e) => e.message, 'packages', contains('unknown 1.0.0'))
              .having((e) => e.message, 'packages', contains('missing 1.0.0'))
              .having(
                (e) => e.message,
                'missing text',
                contains('Missing SPDX standard text: MIT'),
              ),
        ),
      );
    },
  );

  test('identical text is shared but different copyright stays in full', () {
    final text = render(
      metadata([
        package('c', files: {'LICENSE': 'Copyright Bob\nPermission text\n'}),
        package(
          'b',
          files: {'LICENSE': 'Copyright Alice\nPermission text\r\n'},
        ),
        package('a', files: {'LICENSE': 'Copyright Alice\nPermission text\n'}),
      ]),
    );
    expect('Copyright Alice'.allMatches(text), hasLength(1));
    expect(text, contains('与 a 1.0.0 / LICENSE 相同，见上文'));
    expect(text, contains('Copyright Bob\nPermission text\n'));
  });

  test('MPL includes source availability even when the text is shared', () {
    File.fromUri(standards.uri.resolve('MPL-2.0.txt'))
        .writeAsStringSync('MPL text');
    final text = render(
      metadata([
        package('a', license: 'MPL-2.0'),
        package('b', license: 'MPL-2.0'),
      ]),
    );
    expect('源码可从上面的 crates.io 链接获取，本项目未修改这些文件。'.allMatches(text), hasLength(2));
    expect(text, contains('https://crates.io/crates/b/1.0.0'));
  });

  test('license_file works without a Cargo expression', () {
    final text = render(
      metadata([
        package(
          'custom',
          license: null,
          licenseFile: 'terms.txt',
          files: {'terms.txt': 'Permission is hereby granted, free of charge'},
        ),
      ]),
    );
    expect(
      text,
      contains('Cargo license: 未声明（license_file: terms.txt；识别为 MIT）'),
    );
    expect(text, contains('--- terms.txt ---'));
  });

  test('output bytes are stable across repeated and reordered input', () {
    final packages = [
      package('z', files: {'NOTICE': 'Z note', 'LICENSE': 'Z terms'}),
      package('a', version: '2.0.0', files: {'LICENSE': 'A2 terms'}),
      package('a', files: {'LICENSE': 'A terms'}),
    ];
    final first = render(metadata(packages));
    expect(utf8.encode(render(metadata(packages))), utf8.encode(first));
    expect(
      utf8.encode(render(metadata(packages.reversed.toList()))),
      utf8.encode(first),
    );
    expect(first.indexOf('a 1.0.0'), lessThan(first.indexOf('a 2.0.0')));
    expect(first.indexOf('a 2.0.0'), lessThan(first.indexOf('z 1.0.0')));
  });

  test(
    'dev, build and proc-macro-only dependencies do not enter the document',
    () {
      final packages = [
        package('runtime', files: {'LICENSE': 'Runtime terms'}),
        package('build'),
        package('dev'),
        package('macro', macro: true),
        package('macro_child'),
        package('shared', files: {'LICENSE': 'Shared terms'}),
      ];
      final graph = metadata(packages);
      final nodes = graph['resolve']['nodes'] as List;
      nodes.first['deps'][1]['dep_kinds'][0]['kind'] = 'build';
      nodes.first['deps'][2]['dep_kinds'][0]['kind'] = 'dev';
      nodes.first['deps'].removeWhere((d) => d['pkg'] == 'macro_child-1.0.0');
      nodes.firstWhere((n) => n['id'] == 'macro-1.0.0')['deps'] = [
        for (final id in ['macro_child-1.0.0', 'shared-1.0.0'])
          {
            'pkg': id,
            'dep_kinds': [
              {'kind': null},
            ],
          },
      ];
      final text = render(graph);
      expect(text, contains('runtime 1.0.0'));
      expect(text, contains('shared 1.0.0'));
      for (final name in ['build', 'dev', 'macro', 'macro_child', 'root']) {
        expect(text, isNot(contains('$name 1.0.0')));
      }
    },
  );

  test(
    'SPDX groups and LLVM exception are recognized; malformed syntax fails',
    () {
      expect(notices.rustLicenseTerms('(MIT OR Apache-2.0) AND Unicode-3.0'), [
        'MIT',
        'Apache-2.0',
        'Unicode-3.0',
      ]);
      expect(
        notices.rustLicenseTerms('Apache-2.0 WITH LLVM-exception OR MIT'),
        ['Apache-2.0', 'LLVM-exception', 'MIT'],
      );
      for (final expression in [
        '',
        'MIT OR',
        'MIT Apache-2.0',
        '(MIT',
        'MIT)',
        'MIT WITH Unknown',
        'MIT + Apache-2.0',
      ]) {
        expect(
          () => notices.rustLicenseTerms(expression),
          throwsFormatException,
        );
      }
    },
  );

  test('Rust license CLI writes a platform release document', () async {
    final output = File.fromUri(
      temporary.uri.resolve('THIRD_PARTY_LICENSES.txt'),
    );
    final config = jsonDecode(
      File('${root.path}/app/.dart_tool/package_config.json')
          .readAsStringSync(),
    );
    final sdk = Directory.fromUri(Uri.parse(config['flutterRoot'] as String));
    final dart = File.fromUri(
      sdk.uri.resolve(
        'bin/cache/dart-sdk/bin/dart${Platform.isWindows ? '.exe' : ''}',
      ),
    );
    final result = await Process.run(dart.path, [
      '--packages=${root.path}/app/.dart_tool/package_config.json',
      '${root.path}/scripts/generate-desktop-notices.dart',
      '--rust-licenses',
      output.path,
      '--target',
      Platform.isMacOS ? 'aarch64-apple-darwin' : 'x86_64-pc-windows-msvc',
    ], workingDirectory: root.path);

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(output.readAsStringSync(), contains('selectors 0.31.0'));
    expect(
      output.readAsStringSync(),
      contains('data/flutter_assets/NOTICES.Z'),
    );
    final first = output.readAsBytesSync();
    final invalid = await Process.run(dart.path, [
      '--packages=${root.path}/app/.dart_tool/package_config.json',
      '${root.path}/scripts/generate-desktop-notices.dart',
      '--rust-licenses',
      output.path,
      '--target',
      'invalid-target',
    ], workingDirectory: root.path);
    expect(invalid.exitCode, isNot(0));
    expect(
      '${invalid.stderr}',
      contains('Unsupported or missing desktop target'),
    );
    expect(output.readAsBytesSync(), first);
  });
}
