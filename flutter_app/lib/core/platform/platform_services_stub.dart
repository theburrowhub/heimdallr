import 'platform_services.dart';

/// Compile-time fallback for when neither dart:io nor dart:html is available.
/// This file must never actually execute at runtime — the conditional export
/// in `platform_services.dart` picks the real impl for every real build.
///
/// Implements [PlatformServices] via `noSuchMethod` forwarding so the static
/// analyzer sees `PlatformServicesImpl()` as a valid [PlatformServices]. The
/// constructor throws, so no method is ever invoked in practice.
class PlatformServicesImpl implements PlatformServices {
  PlatformServicesImpl() {
    throw UnsupportedError(
      'PlatformServicesImpl stub: no dart:io or dart:html available. '
      'This should be impossible under `flutter run`, `flutter test`, '
      'or `flutter build web`. Check your build tooling.',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
