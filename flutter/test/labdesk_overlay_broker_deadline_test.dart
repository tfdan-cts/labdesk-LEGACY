import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/labdesk/services/overlay_broker.dart';

void main() {
  test('stalled headers and body expire without cancelling another request',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final stalledAccepted = Completer<void>();
    final independentAccepted = Completer<HttpResponse>();
    var stalledCount = 0;
    final subscription = server.listen((request) {
      final token = request.headers.value(HttpHeaders.authorizationHeader);
      final response = request.response;
      if (token == 'Bearer headers' || token == 'Bearer body') {
        if (token == 'Bearer body') {
          response.bufferOutput = false;
          response.write('{"userId":"');
          unawaited(response.flush());
        }
        if (++stalledCount == 2) stalledAccepted.complete();
      } else if (token == 'Bearer independent') {
        independentAccepted.complete(response);
      } else {
        response.write('{"userId":"user","organizations":[]}');
        unawaited(response.close());
      }
    });
    addTearDown(() async {
      await server.close(force: true);
      await subscription.cancel();
    });

    OverlayBroker broker(String token) => OverlayBroker(
          baseUrl: 'http://${server.address.address}:${server.port}',
          token: () => token,
        );
    final deadlineError = isA<TimeoutException>().having(
        (error) => error.duration, 'deadline', const Duration(seconds: 15));
    final expired = Future.wait([
      expectLater(broker('headers').organizations(), throwsA(deadlineError)),
      expectLater(broker('body').organizations(), throwsA(deadlineError)),
    ]);
    await stalledAccepted.future.timeout(const Duration(seconds: 3));

    // Keep a newer exchange open while the two older exchanges are aborted.
    await Future<void>.delayed(const Duration(seconds: 2));
    final independent = expectLater(
        broker('independent').organizations().then((value) => value.userId),
        completion('user'));
    final response =
        await independentAccepted.future.timeout(const Duration(seconds: 3));
    await expired.timeout(const Duration(seconds: 20));
    response.write('{"userId":"user","organizations":[]}');
    await response.close();
    await independent.timeout(const Duration(seconds: 3));
    expect((await broker('immediate').organizations()).userId, 'user');
  }, timeout: const Timeout(Duration(seconds: 25)));
}
