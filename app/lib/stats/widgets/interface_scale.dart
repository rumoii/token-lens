import 'package:flutter/widgets.dart';

class LensInterfaceScale extends StatelessWidget {
  const LensInterfaceScale({
    super.key,
    required this.scale,
    required this.child,
  });

  final double scale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = constraints.biggest / scale;
        return SizedBox.expand(
          child: FittedBox(
            alignment: Alignment.topLeft,
            fit: BoxFit.fill,
            child: SizedBox.fromSize(
              size: viewport,
              child: MediaQuery(
                data: media.copyWith(
                  size: viewport,
                  devicePixelRatio: media.devicePixelRatio * scale,
                  padding: media.padding / scale,
                  viewPadding: media.viewPadding / scale,
                  viewInsets: media.viewInsets / scale,
                  systemGestureInsets: media.systemGestureInsets / scale,
                ),
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}
