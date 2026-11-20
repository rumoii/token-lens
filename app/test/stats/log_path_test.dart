import 'package:flutter_test/flutter_test.dart';
import 'package:token_lens_app/stats/logic/log_path.dart';

void main() {
  test('R2B 06 Windows home matching is case-insensitive', () {
    expect(
      abbreviateHome(
        r'C:\Users\Synthetic\.claude\projects',
        r'c:\users\synthetic',
      ),
      r'~\.claude\projects',
    );
  });

  test('R2B 06 a matching prefix requires a directory separator', () {
    const path = r'C:\Users\Synthetic2\logs';
    expect(abbreviateHome(path, r'C:\Users\Synthetic'), path);
    expect(
      abbreviateHome(r'C:\Users\Synthetic', r'C:\Users\Synthetic'),
      r'C:\Users\Synthetic',
    );
  });

  test('R2B 06 a path outside home stays absolute', () {
    expect(
      abbreviateHome('/var/log/claude', '/home/synthetic'),
      '/var/log/claude',
    );
    expect(abbreviateHome('/var/log/claude', null), '/var/log/claude');
  });

  test('R2B 06 POSIX directories and an optional trailing slash', () {
    expect(
      abbreviateHome('/home/Synthetic/.claude/projects', '/home/synthetic/'),
      '~/.claude/projects',
    );
  });
}
