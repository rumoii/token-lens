import '../../l10n/app_strings.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../../stats_cache.dart';
import '../theme/palette.dart';
import 'primitives.dart';

// Mirrors shared.jsx useResource: old data survives refresh, stale completions do not.
class LensResource<T> {
  LensResource(this.changed);
  final VoidCallback changed;
  T? data;
  Object? error;
  bool ready = false, loading = false, _closed = false;
  Object? _identity;
  int _generation = 0;
  Future<T> Function()? _loader;
  bool get fresh => ready && !loading && error == null;
  void read(
    Object identity,
    Future<T> Function() loader, {
    bool retainData = true,
  }) {
    _loader = loader;
    if (_identity == identity) return;
    _identity = identity;
    if (!retainData) {
      data = null;
      ready = false;
    }
    unawaited(reload());
  }

  Future<void> reload() async {
    if (_closed || _loader == null) return;
    final ticket = ++_generation;
    final load = _loader!;
    error = null;
    try {
      final request = load();
      final T result;
      if (request case StatsCacheHit<T>(:final value)) {
        result = value;
      } else {
        loading = true;
        changed();
        result = await request;
      }
      if (_closed || ticket != _generation) return;
      data = result;
      ready = true;
    } catch (failure) {
      if (_closed || ticket != _generation) return;
      error = failure;
      data = null;
      ready = false;
    } finally {
      if (!_closed && ticket == _generation) {
        loading = false;
        changed();
      }
    }
  }

  void dispose() {
    _closed = true;
    _generation++;
  }
}

class ResourceBlock<T> extends StatelessWidget {
  const ResourceBlock({
    super.key,
    required this.resource,
    required this.builder,
    this.rows = 3,
  });
  final LensResource<T> resource;
  final Widget Function(T? data) builder;
  final int rows;
  @override
  Widget build(BuildContext context) {
    final p = LensPalette.of(context);
    if (resource.error != null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: p['surface-0'],
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, size: 16, color: p['danger']),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.strings.couldNotLoadRequestFailed,
                    style: p.text(12, null, FontWeight.w500),
                  ),
                  Text('${resource.error}', style: p.text(12, p.muted)),
                ],
              ),
            ),
            LensButton(
              label: context.strings.retry,
              size: 'xs',
              variant: 'ghost',
              onPressed: () => unawaited(resource.reload()),
            ),
          ],
        ),
      );
    }
    if (!resource.ready) return SkeletonLines(rows: rows);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (resource.loading) ...[
          Semantics(
            label: context.strings.loading,
            liveRegion: true,
            child: LinearProgressIndicator(
              value: MediaQuery.disableAnimationsOf(context) ? 1 / 3 : null,
              minHeight: 2,
              color: p['clay'],
              backgroundColor: p['fill-hover'],
            ),
          ),
          const SizedBox(height: 8),
        ],
        builder(resource.data),
      ],
    );
  }
}
