import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/labdesk/models/net_view.dart';

/// The machine's own network view, as it rides the `attrs` member of
/// `GET /console/org/machines/:id` (contract section 6). Both keys are written
/// by the agent as JSON text inside an attribute value, so the console parses
/// twice: the attribute, then its content.
Map<String, dynamic> _attr(Object value) => {
      'value': jsonEncode(value),
      'source': 'agent',
      'updatedAt': 1788480300,
    };

void main() {
  test('adapters and the reachability verdict are read off the attributes', () {
    final view = MachineNetView.fromAttrs({
      'net.adapters': _attr([
        {
          'name': 'wlan0',
          'up': false,
          'mac': '11:22:33:44:55:66',
          'addresses': [],
          'rxBytes': 0,
          'txBytes': 0,
          'kind': 'physical',
        },
        {
          'name': 'eth0',
          'up': true,
          'mac': 'aa:bb:cc:dd:ee:ff',
          'addresses': [
            {'addr': '192.168.1.20', 'prefix': 24, 'family': 'inet'},
            {'addr': 'fe80::1', 'prefix': 64, 'family': 'inet6'},
          ],
          'rxBytes': 123456789,
          'txBytes': 23456789,
          'kind': 'physical',
        },
      ]),
      'net.reachability': _attr({
        'internet': 'offline',
        'at': 1788480300,
        'probe': 'tcp443',
        'selfheal': 'cycling',
      }),
    });

    expect(view.reported, isTrue);
    // Up first, so the interface carrying traffic is not under the dead ones.
    expect(view.adapters.first.name, 'eth0');
    expect(view.adapters.first.v4.single.toString(), '192.168.1.20/24');
    expect(view.adapters.first.v6.single.isV6, isTrue);
    expect(view.adapters.last.up, isFalse);
    expect(formatBytes(view.adapters.first.rxBytes), '118 MB');

    expect(view.reachability.internet, 'offline');
    expect(view.reachability.internetLabel, 'No internet');
    expect(view.reachability.selfHealRunning, isTrue);
    expect(view.reachability.selfhealLabel, 'cycling the adapter');
  });

  test('a machine that has reported nothing is not drawn as having no network',
      () {
    const view = MachineNetView.empty;
    expect(view.reported, isFalse);
    expect(view.adapters, isEmpty);
    // Never probed is its own state, and it is not offline.
    expect(view.reachability.internet, 'unprobed');
    expect(view.reachability.internetLabel, 'Not probed yet');
    expect(view.reachability.selfHealRunning, isFalse);
  });
}
