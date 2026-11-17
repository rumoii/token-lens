// Run with the existing app package configuration; never resolves dependencies.
import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

const marker = '<!-- desktop-dependencies:generated -->';

Map<dynamic, dynamic> yamlFile(File file) =>
    loadYaml(file.readAsStringSync()) as Map<dynamic, dynamic>;

String licenseId(String text) {
  final matches = <String>[];
  if (text.contains('Permission is hereby granted, free of charge'))
    matches.add('MIT');
  if (text.contains('Apache License') && text.contains('Version 2.0'))
    matches.add('Apache-2.0');
  if (text.contains('Redistribution and use in source and binary forms')) {
    matches.add(
      text.contains('Neither the name') ? 'BSD-3-Clause' : 'BSD-2-Clause',
    );
  }
  if (text.contains('Permission to use, copy, modify, and/or distribute'))
    matches.add('ISC');
  if (matches.length != 1) {
    throw const FormatException(
      'Unrecognized or combined license text; inspect the package LICENSE.',
    );
  }
  return matches.single;
}

String packageLicense(Directory directory) {
  final licenses = directory
      .listSync()
      .whereType<File>()
      .where(
        (file) => [
          'license',
          'license.md',
          'license.txt',
          'copying',
        ].contains(file.uri.pathSegments.last.toLowerCase()),
      )
      .toList();
  if (licenses.length != 1)
    throw StateError(
      'Expected one LICENSE for ${directory.uri.pathSegments.where((s) => s.isNotEmpty).last}.',
    );
  return licenseId(licenses.single.readAsStringSync());
}

String table(List<List<String>> rows) {
  String row(List<String> cells) =>
      '| ${cells.map((s) => s.replaceAll('|', r'\|')).join(' | ')} |';
  return [
    row(['组件', '版本', '许可证', '口径 / 平台', '链接']),
    row(List.filled(5, '---')),
    ...rows.map(row),
  ].join('\n');
}

/// A normal dependency of a proc macro runs on the host, not in the application.
Map<String, Set<String>> cargoScopes(Map<String, dynamic> metadata) {
  final packages = {for (final p in metadata['packages']) p['id'] as String: p};
  final nodes = {
    for (final n in metadata['resolve']['nodes']) n['id'] as String: n,
  };
  final scopes = {'runtime': <String>{}, 'build': <String>{}};
  void visit(String id, bool host) {
    final macro = (packages[id]['targets'] as List).any(
      (t) => (t['kind'] as List).contains('proc-macro'),
    );
    host = host || macro;
    if (!scopes[host ? 'build' : 'runtime']!.add(id)) return;
    for (final dep in nodes[id]['deps']) {
      for (final kind in dep['dep_kinds']) {
        if (kind['kind'] == null || kind['kind'] == 'build') {
          visit(dep['pkg'] as String, host || kind['kind'] == 'build');
        }
      }
    }
  }

  visit(metadata['resolve']['root'] as String, false);
  return scopes;
}

Future<String> generate(Directory root) async {
  final app = Directory.fromUri(root.uri.resolve('app/'));
  final configFile = File.fromUri(
    app.uri.resolve('.dart_tool/package_config.json'),
  );
  final config =
      jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
  final locations = <String, Directory>{
    for (final p in config['packages'])
      p['name'] as String: Directory.fromUri(
        configFile.uri.resolve(p['rootUri'] as String),
      ),
  };
  final locked =
      yamlFile(File.fromUri(app.uri.resolve('pubspec.lock')))['packages']
          as Map;
  final pubspec = yamlFile(File.fromUri(app.uri.resolve('pubspec.yaml')));
  final packageSpecs = <String, Map<dynamic, dynamic>>{};
  for (final entry in locked.entries) {
    final name = entry.key as String;
    final directory = locations[name];
    if (directory == null)
      throw StateError('Missing resolved Pub package: $name');
    final spec = yamlFile(File.fromUri(directory.uri.resolve('pubspec.yaml')));
    if (entry.value['source'] != 'sdk' &&
        spec['version'].toString() != entry.value['version'].toString()) {
      throw StateError(
        'Package configuration does not match pubspec.lock: $name',
      );
    }
    packageSpecs[name] = spec;
  }
  Set<String> closure(Iterable<String> roots) {
    final found = <String>{};
    void visit(String name) {
      if (!found.add(name)) return;
      final spec = packageSpecs[name];
      if (spec == null)
        throw StateError('Dependency absent from lockfile: $name');
      for (final child in (spec['dependencies'] as Map? ?? {}).keys) {
        visit(child as String);
      }
    }

    roots.forEach(visit);
    return found;
  }

  // The app imports this package only from hook/build.dart.
  final runtime = closure(
    (pubspec['dependencies'] as Map).keys.cast<String>().where(
      (name) => name != 'flutter_rust_bridge_hooks',
    ),
  );
  final build = closure(['flutter_rust_bridge_hooks']);
  final dartRows = <List<String>>[];
  final toolingRows = <List<String>>[];
  for (final name in (locked.keys.cast<String>().toList()..sort())) {
    final info = locked[name] as Map;
    final spec = packageSpecs[name]!;
    final sdk = info['source'] == 'sdk';
    final licenseDirectory = sdk
        ? locations['flutter']!.parent.parent
        : locations[name]!;
    final license = name == 'sky_engine'
        ? '多许可证（Flutter Engine 许可合集）'
        : packageLicense(licenseDirectory);
    final version = sdk
        ? '${info['version']}（Flutter ${config['flutterVersion']}）'
        : info['version'].toString();
    var scope = runtime.contains(name)
        ? (build.contains(name) ? '运行时 / 构建声明图共用' : '运行时声明图上界')
        : build.contains(name)
        ? '仅构建 hook'
        : '仅开发 / 测试';
    final flutter = spec['flutter'];
    final plugin = flutter is Map ? flutter['plugin'] : null;
    final platforms = plugin is Map ? plugin['platforms'] : null;
    if (platforms is Map) scope += '；插件 ${platforms.keys.join('/')}';
    final link = sdk
        ? 'https://github.com/flutter/flutter/tree/${config['flutterVersion']}'
        : 'https://pub.dev/packages/$name/versions/${info['version']}/license';
    (runtime.contains(name) ? dartRows : toolingRows).add([
      name,
      version,
      license,
      scope,
      link,
    ]);
  }

  final rustPackages = <String, Map<String, dynamic>>{};
  final rustRuntime = <String, Set<String>>{};
  final rustBuild = <String, Set<String>>{};
  for (final target in {
    'x86_64-pc-windows-msvc': 'Windows x64',
    'aarch64-apple-darwin': 'macOS arm64',
  }.entries) {
    final result = await Process.run('cargo', [
      'metadata',
      '--manifest-path',
      'app/rust/Cargo.toml',
      '--locked',
      '--offline',
      '--format-version',
      '1',
      '--filter-platform',
      target.key,
    ], workingDirectory: root.path);
    if (result.exitCode != 0)
      throw StateError(
        'cargo metadata failed for ${target.key}: ${result.stderr}',
      );
    final metadata =
        jsonDecode(result.stdout as String) as Map<String, dynamic>;
    final scopes = cargoScopes(metadata);
    for (final dynamic p in metadata['packages']) {
      final package = p as Map<String, dynamic>;
      final id = package['id'] as String;
      if (id == metadata['resolve']['root']) continue;
      if (!scopes['runtime']!.contains(id) && !scopes['build']!.contains(id))
        continue;
      final key = '${package['name']} ${package['version']}';
      rustPackages[key] = package;
      if (scopes['runtime']!.contains(id))
        (rustRuntime[key] ??= {}).add(target.value);
      if (scopes['build']!.contains(id))
        (rustBuild[key] ??= {}).add(target.value);
    }
  }
  final rustRows = <List<String>>[];
  final rustToolRows = <List<String>>[];
  for (final key in (rustPackages.keys.toList()..sort())) {
    final package = rustPackages[key]!;
    var license = package['license'] as String?;
    if (license == null) {
      final licenseFile = package['license_file'] as String?;
      if (licenseFile == null) throw StateError('Missing crate license: $key');
      final manifest = File(package['manifest_path'] as String);
      license = licenseId(
        File.fromUri(manifest.parent.uri.resolve(licenseFile))
            .readAsStringSync(),
      );
    }
    final platforms = rustRuntime[key] ?? rustBuild[key]!;
    final scope = rustRuntime.containsKey(key)
        ? '运行时${rustBuild.containsKey(key) ? ' / 构建共用' : ''}'
        : '仅构建 / proc-macro';
    final row = [
      package['name'].toString(),
      package['version'].toString(),
      license,
      '$scope；${platforms.join('、')}',
      'https://crates.io/crates/${package['name']}/${package['version']}',
    ];
    (rustRuntime.containsKey(key) ? rustRows : rustToolRows).add(row);
  }
  return '''$marker
## 桌面应用的 Dart/Flutter 依赖

由 [scripts/generate-desktop-notices.dart](scripts/generate-desktop-notices.dart) 根据 `app/pubspec.lock`、已解析的 Pub 缓存包 `pubspec.yaml` / LICENSE 和 Flutter SDK 生成。SDK：Flutter ${config['flutterVersion']}、Dart ${config['generatorVersion']}。保留完整生产依赖声明图作为分发清单上界，包含条件导入、其他平台实现及工具传递项；不是 AOT tree-shaking 后的逐符号清单。SDK 的 0.0.0 是锁文件占位版本。

${table(dartRows)}

### Dart 开发与构建依赖（不作为运行时依赖计入）

应用的 `hook/build.dart` 使用 flutter_rust_bridge_hooks；其独有传递依赖标为仅构建，其余仅开发/测试项也单列。生产声明图与构建图共用的包保守列在上表。Flutter Engine 的聚合许可由 SDK 的 sky_engine/license 提供，发布目录内的 `data/flutter_assets/NOTICES.Z` 保留 Flutter 自动收集的许可全文；macOS 对应 `.app` 内的 Flutter assets。引擎合集包含多种许可证。

${table(toolingRows)}

## 桌面应用的 Rust 依赖

依据 `cargo metadata --locked --offline --filter-platform <target>`，分别遍历 Windows x64（x86_64-pc-windows-msvc）和 macOS arm64（aarch64-apple-darwin）的已启用 normal 依赖。build 边与 proc-macro 及其传递依赖单列；dev 边排除。两类共用包仍列在运行时表。许可证表达式保留 Cargo metadata 原文，缺省表达式时读取包的 license_file；不替双重许可包作选证决定。版本各自列出，不合并同名不同版本；平台按目标依赖图标注，未按最终链接器消除的符号裁剪。

${table(rustRows)}

### Rust 构建依赖与 proc-macro（不作为运行时依赖计入）

${table(rustToolRows)}

### 更新清单

先使用项目已有 Flutter/Pub 和 Cargo 缓存完成锁定依赖解析，再在仓库根运行：

```sh
dart --packages=app/.dart_tool/package_config.json scripts/generate-desktop-notices.dart
dart --packages=app/.dart_tool/package_config.json scripts/generate-desktop-notices.dart --check
```

脚本不安装工具、不解析新版本，Cargo 始终 locked/offline；缓存缺失或许可证无法识别时失败。只替换本生成标记之后的内容，保留前面的旧版声明。`--check` 不写文件，清单过期时返回非零。许可证全文以各链接、缓存中的许可文件及 Flutter 产物 NOTICES 为准；此清单不等于法律适用性判断。
''';
}

Future<void> main(List<String> args) async {
  if (args.any((arg) => arg != '--check'))
    throw const FormatException('Only --check is supported.');
  final root = File.fromUri(Platform.script).parent.parent;
  final notices = File.fromUri(root.uri.resolve('THIRD_PARTY_NOTICES.md'));
  final original = notices.readAsStringSync();
  final at = original.indexOf(marker);
  final prefix = at < 0
      ? '$original${original.endsWith('\n') ? '\n' : '\n\n'}'
      : original.substring(0, at);
  final updated = '$prefix${await generate(root)}';
  if (args.contains('--check')) {
    if (updated != original) {
      stderr.writeln(
        'THIRD_PARTY_NOTICES.md is out of date; run the generator.',
      );
      exitCode = 1;
    } else {
      stdout.writeln('Desktop dependency notices are current.');
    }
  } else {
    notices.writeAsStringSync(updated);
    stdout.writeln('Updated desktop dependency notices.');
  }
}
