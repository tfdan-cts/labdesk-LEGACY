import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/labnet.dart';
import '../models/machine_metrics.dart';
import '../models/machine_state.dart';
import '../models/net_view.dart';
import '../models/organization_context.dart';
import '../models/health_event.dart';

/// One HTTP exchange: status code and body text. Injected so the broker can
/// be exercised without a network and run on `HttpClient` in the application.
typedef HttpCall = Future<(int, String)> Function(
    String method, Uri url, Map<String, String> headers, String? body);

/// Signs one machine-plane request and hands back the three headers
/// lab-desk.net reads, or null when this process cannot speak for the machine.
///
/// The client cannot do this itself: the agent key is kept where an
/// interactive user cannot read it (`src/labdesk/identity.rs`), so the
/// privileged LabDesk process signs on request over IPC
/// (`src/labdesk/labnet.rs`) and only the answer crosses. `main_agent_sign` in
/// `src/flutter_ffi.rs` is the implementation; it answers "" when nobody could
/// speak for the machine, which is what an unenrolled machine gets.
typedef MachineSigner = Future<MachineSignature?> Function(
    String method, String path, String body);

/// The three headers `agentAuth` reads on `/agent/*`
/// (`src/worker/agent-auth.ts`): the machine id it looks the key up by, the
/// timestamp it bounds replay with, and the detached Ed25519 signature over
/// the method, the path, that timestamp and the hash of the body.
class MachineSignature {
  const MachineSignature({
    required this.machine,
    required this.ts,
    required this.sig,
  });

  final String machine;
  final String ts;
  final String sig;

  /// What `main_agent_sign` answers: `{"machine","ts","sig"}`, and `""` when
  /// this process holds no machine credential. Anything short of all three is
  /// read as "cannot sign" rather than sent as a partial credential.
  static MachineSignature? decode(String json) {
    try {
      final j = jsonDecode(json);
      if (j is! Map) return null;
      final machine = j['machine'], ts = j['ts'], sig = j['sig'];
      if (machine is! String || ts is! String || sig is! String) return null;
      if (machine.isEmpty || ts.isEmpty || sig.isEmpty) return null;
      return MachineSignature(machine: machine, ts: ts, sig: sig);
    } catch (_) {
      return null;
    }
  }

  Map<String, String> get headers => {
        'x-ld-machine': machine,
        'x-ld-ts': ts,
        'x-ld-sig': sig,
      };
}

/// What lab-desk.net answered when it refused.
class OverlayBrokerException implements Exception {
  const OverlayBrokerException(this.status, this.message,
      {this.machinePlane = false});
  final int status;
  final String message;

  /// The call never left this machine: the console holds no agent key, so a
  /// machine-plane request was refused before any network was touched.
  bool get refusedHere => status == OverlayBroker._refusedHere;

  /// Whether the refusal came from the machine plane, where 401 means the
  /// signature was refused and has nothing to do with an account.
  final bool machinePlane;

  /// The device's sign-in no longer holds; the console asks for it again.
  bool get signInAgain => status == 401 && !machinePlane;

  /// The token is good but too old for a change this sensitive. `actor()`
  /// refuses full access, deleting a labnet, minting an enrolment token and
  /// creating a fleet on any console token older than `FRESH_SECONDS`
  /// (`src/worker/org.ts`), and the answer is this one sentence. The console
  /// signs in again and retries rather than telling the operator to restart.
  bool get needsFreshSignIn =>
      status == 403 && !machinePlane && message.startsWith('Sign in again');

  @override
  String toString() => message;
}

class Enrolment {
  const Enrolment({required this.setupKey, required this.managementUrl});
  final String setupKey;
  final String managementUrl;
}

/// A machine as lab-desk.net holds it: the id every labnet route names it by,
/// the peer id the client knows the same machine as, and what to call it on
/// screen.
class OrgMachine {
  const OrgMachine({
    required this.id,
    required this.peerId,
    required this.name,
    this.platform = '',
    this.fleetId,
    this.state = const MachineState(),
  });

  /// `machine.id`, minted by the Worker at `/agent/enrol`.
  final String id;

  /// `machine.peerId`, the id in the connect box.
  final String peerId;
  final String name;
  final String platform;
  final String? fleetId;

  /// The hot row beside the machine, from `?state=1`. Every reading is null
  /// until the agent has sent one.
  final MachineState state;
}

/// One fleet of the organization, for the picker a narrowed technician needs
/// when creating a labnet (`GET /console/org/fleets`).
class OrgFleet {
  const OrgFleet({required this.id, required this.name});
  final String id;
  final String name;
}

class SessionGrant {
  const SessionGrant({
    required this.id,
    required this.targetAddr,
    required this.targetIdPk,
    this.ticket = '',
  });
  final String id;

  /// `ip:port` on the overlay.
  final String targetAddr;

  /// The target's own id public key, so the direct session still runs the
  /// key exchange the rendezvous path performs.
  final String targetIdPk;

  /// The connect ticket's secret, minted with the grant and spent once by
  /// the client on the connect (`docs/plans/2026-09-05-002-phase1-contracts.md`
  /// section 3). Empty when the Worker minted none.
  final String ticket;
}

/// The labnet routes on lab-desk.net.
///
/// They sit on TWO planes, and which plane a route is on decides what
/// authorizes it (plan section 0.4):
///
/// * The MACHINE plane, `/agent/overlay/*` (`src/worker/routes/agent-overlay.ts`).
///   lab-desk.net reads no `Authorization` header there at all: the caller is
///   whichever machine holds the secret half of `machine.agentPk`, proven by a
///   detached signature over the request. Every route on it acts on this
///   machine's own labnet identity, so nothing in the request names a machine
///   and there is nothing for a caller to choose.
/// * The HUMAN plane, `/console/overlay/*` and `/console/org/*`: the handlers
///   of `/api/overlay/*` and `/api/org/*` (`src/worker/routes/overlay.ts`,
///   `src/worker/routes/org.ts`) mounted a second time under `/console`. Every
///   route calls `actor()`, which resolves the signed-in person and their
///   organization from the app token `/api/login` mints. These are the labnets
///   an organization holds and the session grant a technician opens.
///
/// WHY `/console` AND NEVER `/api`: while lab-desk.net is private, `/api/*` sits
/// behind a Cloudflare Access wall that answers a bearer with a 302 to its
/// sign-in page, and the bypass that lets this desktop through carries `/agent`
/// and `/console` only. A human-plane call built on `/api/` would never reach a
/// handler, so none is.
///
/// The MACHINE plane is signed for this process by the privileged LabDesk
/// process, which holds the agent key and answers over IPC (`main_agent_sign`,
/// `src/labdesk/labnet.rs`). [sign] answers null only when that process could
/// not speak for the machine, which is what a machine nobody has enrolled
/// gets, and every machine-plane call is then refused before the wire.
///
/// The human plane does not wait on the machine plane: everything an account
/// does to an organization's labnets is reachable with no agent key at all.
class OverlayBroker {
  OverlayBroker({
    required this.baseUrl,
    required this.token,
    this.sign = _noMachineKey,
    this.peerId = _noPeerId,
    this.machineIdOf = _asGiven,
    this.organizationId,
    HttpCall? http,
  }) : _http = http ?? _httpClient;

  final String baseUrl;

  /// The account's own token, read afresh on every call so a re-sign-in is
  /// picked up at once.
  final String Function() token;

  /// The machine credential. A broker built without one speaks the human plane
  /// only, which is what a process that cannot read the agent key can do.
  final MachineSigner sign;

  /// This machine's own peer id: what the client calls it in the connect box
  /// and everywhere else it names a machine.
  final String Function() peerId;

  /// A peer id turned into the `machine.id` lab-desk.net names machines by,
  /// from the map [machines] reads. The default answers what it was given, for
  /// a caller that already holds machine ids.
  final String Function(String peerId) machineIdOf;
  final String? Function()? organizationId;

  final HttpCall _http;

  /// Pins a remote operation to the account, organization and target it began
  /// with. A later switch must not redirect readiness checks or grant cleanup.
  OverlayBroker captureScope({String? targetPeerId}) {
    final credential = token();
    final organization = organizationId?.call();
    final controllerPeer = peerId();
    final controller = machineIdOf(controllerPeer);
    final target = targetPeerId == null ? null : machineIdOf(targetPeerId);
    return OverlayBroker(
      baseUrl: baseUrl,
      token: () => credential,
      organizationId: () => organization,
      sign: sign,
      peerId: () => controllerPeer,
      machineIdOf: (id) => id == targetPeerId ? target! :
          id == controllerPeer ? controller : machineIdOf(id),
      http: _http,
    );
  }

  static Future<MachineSignature?> _noMachineKey(
          String method, String path, String body) async =>
      null;

  static String _noPeerId() => '';

  static String _asGiven(String peerId) => peerId;

  static List<Map> _rows(Object? v) =>
      v is List ? v.whereType<Map>().toList() : const [];

  static String _str(Object? v) => v is String ? v : '';

  /// What a machine with no credential of its own is told, before anything is
  /// sent: the machine plane would refuse it, and a doomed request every
  /// fifteen seconds is not a better answer than this one.
  static const _noKey =
      'This machine is not enrolled with an organization yet, so it cannot '
      'speak for itself on lab-desk.net. Enrol it under This machine.';

  /// The status on a refusal this client made itself, before any request. No
  /// HTTP status is 0, so a caller can tell one from anything a server said.
  static const _refusedHere = 0;

  static Future<(int, String)> _httpClient(
      String method, Uri url, Map<String, String> headers, String? body) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    HttpClientRequest? request;
    const deadline = Duration(seconds: 15);
    try {
      return await (() async {
        final req = await client.openUrl(method, url);
        request = req;
        headers.forEach(req.headers.set);
        if (body != null) req.write(body);
        final res = await req.close();
        return (res.statusCode, await res.transform(utf8.decoder).join());
      })().timeout(deadline, onTimeout: () {
        final error = TimeoutException(
            'lab-desk.net did not respond within 15 seconds.', deadline);
        request?.abort(error);
        throw error;
      });
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _send(String method, String path,
      Map<String, String> credential, String? body, bool machinePlane) async {
    final headers = {
      ...credential,
      'accept': 'application/json',
      if (body != null) 'content-type': 'application/json',
    };
    final (status, text) =
        await _http(method, Uri.parse('$baseUrl$path'), headers, body);
    Map<String, dynamic> json = const {};
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) json = decoded;
    } catch (_) {}
    if (status == 202 &&
        (path.endsWith('/leave') ||
            (method == 'DELETE' && path.contains('/members/')))) {
      final message = json['message'];
      throw OverlayBrokerException(
          status,
          message is String && message.isNotEmpty
              ? message
              : 'Network removal is still pending. Retry to check progress.',
          machinePlane: machinePlane);
    }
    if (status < 200 || status >= 300) {
      final message = json['error'];
      throw OverlayBrokerException(
          status,
          message is String && message.isNotEmpty
              ? message
              : 'lab-desk.net answered $status',
          machinePlane: machinePlane);
    }
    return json;
  }

  /// A call on the human plane, carrying the account's token and no signature.
  Future<Map<String, dynamic>> _human(String method, String path,
          [Map<String, dynamic>? body]) =>
      _send(
          method,
          path,
          {
            'authorization': 'Bearer ${token()}',
            if (organizationId?.call() case final String id when id.isNotEmpty)
              'x-labdesk-organization': id,
          },
          body == null ? null : jsonEncode(body),
          false);

  /// Lists memberships without a selected context, including after a saved
  /// membership was revoked. The machine signing plane never sends this header.
  Future<OrganizationDirectory> organizations() async {
    final response = await _send('GET', '/console/organizations',
        {'authorization': 'Bearer ${token()}'}, null, false);
    final rows = response['organizations'];
    final userId = response['userId'];
    if (rows is! List || userId is! String || userId.isEmpty || userId.length > 128) {
      throw const OverlayBrokerException(
          502, 'The organization list could not be read.');
    }
    return OrganizationDirectory(userId: userId, organizations: rows
        .map(OrganizationSummary.fromJson)
        .whereType<OrganizationSummary>()
        .toList());
  }

  /// Verifies membership before the caller adopts a new desktop context.
  Future<String> verifyOrganization(String id) async {
    if (id.isEmpty || id.length > 128 || id.contains(RegExp(r'[\r\n]'))) {
      throw const OverlayBrokerException(400, 'Choose a valid organization.');
    }
    final response = await _send(
        'GET',
        '/console/org',
        {
          'authorization': 'Bearer ${token()}',
          'x-labdesk-organization': id,
        },
        null,
        false);
    if (response['orgId'] != id) {
      throw const OverlayBrokerException(
          403, 'The selected organization could not be verified.');
    }
    return id;
  }

  /// A call on the machine plane, carrying the signature and no token.
  ///
  /// The body is encoded once and signed as the bytes that go on the wire: the
  /// server hashes what it received, so a body re-encoded between signing and
  /// sending would be refused.
  Future<Map<String, dynamic>> _machine(String method, String path,
      [Map<String, dynamic>? body]) async {
    final text = body == null ? null : jsonEncode(body);
    final signature = await sign(method, path, text ?? '');
    if (signature == null) {
      throw const OverlayBrokerException(_refusedHere, _noKey,
          machinePlane: true);
    }
    return _send(method, path, signature.headers, text, true);
  }

  Future<Enrolment> enrol() async {
    final j = await _machine('POST', '/agent/overlay/enrol', {});
    return Enrolment(
        setupKey: '${j['setupKey']}', managementUrl: '${j['managementUrl']}');
  }

  Future<void> reportSelf({
    required String overlayIp,
    required String publicKey,
    required String idPk,
    required int directPort,
  }) =>
      _machine('POST', '/agent/overlay/self', {
        'overlayIp': overlayIp,
        'publicKey': publicKey,
        'idPk': idPk,
        'directPort': directPort,
      });

  Future<void> revoke() => _machine('DELETE', '/agent/overlay/enrol');

  /// A one-way path to the machine the client knows as [targetPeerId].
  ///
  /// TWO ID DOMAINS MEET HERE, and this is the only place they may. The client
  /// names a machine by its peer id; every labnet route resolves a machine
  /// through `actor()` against `machine.id`, which the Worker minted at
  /// `/agent/enrol` and which no peer id is (`src/worker/routes/overlay.ts`).
  /// Both ends are mapped, the controlling one included: a device id in a
  /// request body is never an authorization subject, so naming this machine
  /// costs nothing and the server checks both against the caller's
  /// organization. An id [machineIdOf] does not hold is sent empty rather than
  /// as a peer id, because a machine lab-desk.net cannot name is one it must
  /// refuse.
  Future<SessionGrant> session(String targetPeerId, {String mode = 'desktop'}) async {
    final j = await _human('POST', '/console/overlay/session', {
      'controller': machineIdOf(peerId()),
      'target': machineIdOf(targetPeerId),
      'mode': mode,
      'permissionsVersion': 1,
    });
    final ticket = j['ticket'];
    return SessionGrant(
        id: '${j['id']}',
        targetAddr: '${j['targetAddr']}',
        targetIdPk: '${j['targetIdPk']}',
        ticket: ticket is Map ? '${ticket['secret'] ?? ''}' : '');
  }

  Future<Map<String, dynamic>> connectPermissions(String targetPeerId) =>
      _human('GET', '/console/org/machines/${Uri.encodeComponent(machineIdOf(targetPeerId))}/connect-permissions');

  Future<Map<String, dynamic>> setConnectPermissions(String targetPeerId,
          List<String> capabilities, int revision) =>
      _human('PUT', '/console/org/machines/${Uri.encodeComponent(machineIdOf(targetPeerId))}/connect-permissions',
          {'capabilities': capabilities, 'revision': revision});

  /// True only after the target's privileged agent installed the one-time
  /// ticket in its listener. A WireGuard connection alone cannot prove this.
  Future<bool> sessionReady(String id) async =>
      (await _human('GET',
              '/console/overlay/session/${Uri.encodeComponent(id)}/ready'))[
          'ready'] ==
      true;

  /// Recheck the exact claimed connection before using its cached terminal.
  Future<bool> sessionAuthorized(String id, String targetPeerId, String mode) async {
    final query = Uri(queryParameters: {
      'mode': mode,
      'controller': machineIdOf(peerId()),
      'target': machineIdOf(targetPeerId),
    }).query;
    return (await _human('GET',
        '/console/overlay/session/${Uri.encodeComponent(id)}/ready?$query'))['authorized'] == true;
  }

  /// Best effort: a session that is over is over whether or not the release
  /// lands; the server sweeps what a dead client leaves behind.
  Future<bool> endSession(String id) async {
    try {
      await _human('DELETE', '/console/overlay/session/$id');
      return true;
    } on OverlayBrokerException catch (e) {
      return e.status == 404 || e.status == 410;
    } catch (_) {
      return false;
    }
  }

  /// The organization's machines (`GET /console/org/machines`,
  /// `src/worker/routes/org.ts`), narrowed by the server to the caller's org
  /// and fleets. It is the only route on which `machine.id` and the peer id
  /// appear together, so it is both the map [machineIdOf] is built from and the
  /// console's own list of the machines an account may invite.
  /// `?state=1`, so the hot row rides the same answer in the same left join
  /// rather than one request per machine (contract section 5).
  Future<List<OrgMachine>> machines() async {
    final j = await _human('GET', '/console/org/machines?state=1');
    return [
      for (final m in _rows(j['machines']))
        OrgMachine(
          id: _str(m['id']),
          peerId: _str(m['peerId']),
          name: _str(m['displayName']).isNotEmpty
              ? _str(m['displayName'])
              : _str(m['hostname']),
          platform: _str(m['platform']),
          fleetId: m['fleetId'] is String ? m['fleetId'] as String : null,
          state: MachineState.fromJson(m),
        ),
    ];
  }

  /// The hot row for one machine, which carries what the fleet answer does not:
  /// uptime, the signed-in user and the agent version.
  /// Changes only this machine's stored collector policy. The next successful
  /// upload delivers it to the collector; it is not an immediate refresh.
  Future<void> setReportingInterval(String machineId, int seconds) async {
    if (machineId.isEmpty || machineId.length > 200 || seconds < 60 || seconds > 86400) {
      throw const OverlayBrokerException(400, 'Choose a reporting interval from 60 to 86400 seconds.');
    }
    final response = await _human('PATCH',
      '/console/org/machines/${Uri.encodeComponent(machineId)}/reporting',
      {'flushSeconds': seconds});
    if (response['machineId'] != machineId || response['flushSeconds'] != seconds) {
      throw const OverlayBrokerException(502, 'The service did not confirm the reporting interval. Refresh before retrying.');
    }
  }

  Future<MachineState> machineState(String machineId) async =>
      MachineState.fromJson(
          await _human('GET', '/console/org/machines/$machineId/state'));

  /// The machine's own network view, read out of the agent attributes on
  /// `GET /console/org/machines/:id` (contract section 6).
  Future<MachineNetView> netView(String machineId) async {
    final j = await _human('GET', '/console/org/machines/$machineId');
    final attrs = j['attrs'];
    return attrs is Map
        ? MachineNetView.fromAttrs(attrs)
        : MachineNetView.empty;
  }

  /// The stored history over a range, in unix seconds.
  Future<List<MetricSample>> metrics(String machineId,
      {required int from, required int to}) async {
    final j = await _human(
        'GET', '/console/org/machines/$machineId/metrics?from=$from&to=$to');
    return parseMetricHistory(j);
  }

  /// The fleets this caller may name, for the create form.
  Future<List<OrgFleet>> fleets() async {
    final j = await _human('GET', '/console/org/fleets');
    return [
      for (final f in _rows(j['fleets']))
        OrgFleet(id: _str(f['id']), name: _str(f['name'])),
    ];
  }

  Future<String> organizationRole() async =>
      _str((await _human('GET', '/console/org'))['role']);

  Future<void> renameProfile(String name) =>
      _human('PATCH', '/console/me/profile', {'name': name});

  Future<void> renameMachine(String machineId, String name) => _human('PATCH',
      '/console/org/machines/${Uri.encodeComponent(machineId)}',
      {'displayName': name});

  Future<void> renameFleet(String fleetId, String name) => _human('PATCH',
      '/console/org/fleets/${Uri.encodeComponent(fleetId)}', {'name': name});

  Future<Map<String, dynamic>> downloadLinks() =>
      _human('GET', '/console/download-links');

  Future<Map<String, dynamic>> createDownloadLink(String platform,
          {String? fleetId}) =>
      _human('POST', '/console/download-links', {
        'platform': platform,
        if (fleetId != null) 'fleetId': fleetId,
      });

  Future<void> revokeDownloadLink(String id) =>
      _human('DELETE', '/console/download-links/${Uri.encodeComponent(id)}');

  Future<Map<String, dynamic>> updates() =>
      _human('GET', '/console/org/updates');

  Future<void> setUpdatePolicy(List<String> machineIds,
          {required bool automatic,
          required ({List<int> days, int startMinute, int windowMinutes})? weekly}) =>
      _human('PUT', '/console/org/update-policies', {
        'machineIds': machineIds,
        'automatic': automatic,
        'weekly': weekly == null ? null : {
          'days': weekly.days,
          'startMinute': weekly.startMinute,
          'windowMinutes': weekly.windowMinutes,
        },
      });

  Future<Map<String, dynamic>> scheduleUpdates(List<String> machineIds,
          {required String action, required DateTime startsAt,
          required DateTime endsAt}) =>
      _human('POST', '/console/org/update-commands', {
        'machineIds': machineIds,
        'action': action,
        'startsAt': startsAt.millisecondsSinceEpoch ~/ 1000,
        'endsAt': endsAt.millisecondsSinceEpoch ~/ 1000,
      });

  Future<Map<String, dynamic>> cancelUpdate(String commandId) =>
      _human('DELETE', '/console/org/update-commands/${Uri.encodeComponent(commandId)}');

  Future<Map<String, dynamic>> labnetInvitations(String labnetId) =>
      _human('GET', '/console/overlay/labnets/${Uri.encodeComponent(labnetId)}/invitations');

  Future<Map<String, dynamic>> createLabnetInvitation(String labnetId,
          {required String kind, required String delivery, String? email,
          List<String> capabilities = const []}) =>
      _human('POST', '/console/overlay/labnets/${Uri.encodeComponent(labnetId)}/invitations', {
        'kind': kind, 'delivery': delivery, 'capabilities': capabilities,
        if (email != null) 'email': email,
      });

  Future<Map<String, dynamic>> revokeLabnetInvitation(String labnetId, String invitationId) =>
      _human('DELETE', '/console/overlay/labnets/${Uri.encodeComponent(labnetId)}/invitations/${Uri.encodeComponent(invitationId)}');

  Future<void> setLabnetAccess(String labnetId, String accessId, List<String> capabilities) =>
      _human('PATCH', '/console/overlay/labnets/${Uri.encodeComponent(labnetId)}/access/${Uri.encodeComponent(accessId)}', {'capabilities': capabilities});

  Future<Map<String, dynamic>> sharedLabnets() => _human('GET', '/console/shared-labnets');

  Future<Map<String, dynamic>> leaveSharedLabnet(String accessId) =>
      _human('DELETE', '/console/shared-labnets/${Uri.encodeComponent(accessId)}');

  Future<Map<String, dynamic>> machineRouting(String machineId) =>
      _human('GET', '/console/overlay/machines/${Uri.encodeComponent(machineId)}/routing');

  Future<Map<String, dynamic>> hostingOffers() => _machine('GET', '/agent/overlay/routing');

  Future<Map<String, dynamic>> setMachineRouting(String machineId,
          {required String? exitId, required int revision, required bool allowLocalLan}) =>
      _human('PUT', '/console/overlay/machines/${Uri.encodeComponent(machineId)}/routing',
          {'exitId': exitId, 'revision': revision, 'allowLocalLan': allowLocalLan});

  Future<Map<String, dynamic>> exitOffers(String labnetId) =>
      _human('GET', '/console/overlay/labnets/${Uri.encodeComponent(labnetId)}/exits');

  Future<Map<String, dynamic>> offerExit(String labnetId, String machineId, {bool allowExitLan = false}) =>
      _human('POST', '/console/overlay/labnets/${Uri.encodeComponent(labnetId)}/exits',
          {'machineId': machineId, 'allowExitLan': allowExitLan});

  Future<Map<String, dynamic>> revokeExit(String exitId) =>
      _human('DELETE', '/console/overlay/exits/${Uri.encodeComponent(exitId)}');

  Future<Map<String, dynamic>> subnets(String labnetId) =>
      _human('GET', '/console/overlay/labnets/${Uri.encodeComponent(labnetId)}/subnets');

  Future<Map<String, dynamic>> shareSubnet(String labnetId,
          {required String machineId, required String name, required String cidr}) =>
      _human('POST', '/console/overlay/labnets/${Uri.encodeComponent(labnetId)}/subnets',
          {'machineId': machineId, 'name': name, 'cidr': cidr});

  Future<Map<String, dynamic>> removeSubnet(String subnetId) =>
      _human('DELETE', '/console/overlay/subnets/${Uri.encodeComponent(subnetId)}');

  /// The service applies organization and fleet authorization and returns its
  /// newest 500 events. A malformed response is not an empty alert list.
  Future<List<HealthEvent>> healthEvents() async {
    final orgId = organizationId?.call();
    final response = await _human('GET', '/console/org/events');
    try {
      final rows = response['events'];
      if (rows is! List || rows.length > 500) {
        throw const FormatException('Invalid alerts');
      }
      final events = rows.map(HealthEvent.fromJson).toList();
      if (events.map((event) => event.id).toSet().length != events.length ||
          (orgId != null && events.any((event) => event.orgId != orgId))) {
        throw const FormatException('Invalid alert scope');
      }
      return List.unmodifiable(events);
    } on FormatException {
      throw const OverlayBrokerException(
          502, 'The alert list could not be read. Refresh to try again.');
    }
  }

  /// The response accepts the request; callers read the event again to show
  /// persisted acknowledgment time and actor instead of inventing either.
  Future<void> acknowledgeHealthEvent(String id) async {
    if (id.isEmpty || id.length > 128 || id.contains(RegExp(r'[\x00-\x1f]'))) {
      throw const OverlayBrokerException(400, 'Choose a valid alert.');
    }
    final response = await _human(
        'POST', '/console/org/events/${Uri.encodeComponent(id)}/ack', {});
    if (response['ok'] != true) {
      throw const OverlayBrokerException(
          502, 'The service did not confirm the acknowledgment request.');
    }
  }

  Future<OrgFleet> createFleet(String name) async {
    final j = await _human('POST', '/console/org/fleets', {'name': name});
    final id = _str(j['id']);
    if (id.isEmpty) {
      throw const OverlayBrokerException(
          502, 'The server did not return the new fleet.');
    }
    return OrgFleet(
        id: id, name: _str(j['name']).isEmpty ? name : _str(j['name']));
  }

  Future<String> mintEnrolmentToken({String? fleetId}) async {
    final j = await _human('POST', '/console/org/enrol-token', {
      if (fleetId != null && fleetId.isNotEmpty) 'fleetId': fleetId,
    });
    final token = _str(j['token']);
    if (token.isEmpty) {
      throw const OverlayBrokerException(
          502, 'The server did not return an enrollment token.');
    }
    return token;
  }

  /// The caller's own standing. `fleetIds` is null for an actor who sees the
  /// whole organization and a list for one narrowed to fleets, which is what
  /// decides whether creating a labnet has to name a fleet.
  Future<List<String>?> fleetIds() async {
    final j = await _human('GET', '/console/org');
    final ids = j['fleetIds'];
    return ids is List ? [for (final i in ids) '$i'] : null;
  }

  /// What the Network section shows, read off BOTH planes because the two
  /// halves belong to two different subjects.
  ///
  /// * This machine's own standing and the invitations waiting on it come from
  ///   `GET /agent/overlay/inbox`, which answers for the machine that signed
  ///   and for no other (`src/worker/routes/agent-overlay.ts`).
  /// * The labnets come from `GET /console/overlay/labnets`, the route that
  ///   replaced the old console inbox (`src/worker/routes/overlay.ts`). It
  ///   answers the ORGANIZATION's labnets, which is what the person managing
  ///   them is looking at. The machine plane's own list is deliberately not
  ///   read: it holds only labnets this machine has joined, so a labnet just
  ///   created, or one whose members are still deciding, would be missing from
  ///   the screen of the technician who made it.
  ///
  /// The keys are the Worker's, not the client's: a member is `machineId` and
  /// there is no `owner` on either route.
  Future<LabnetInbox> inbox() async {
    final mine = await _mine();
    final theirs = await _human('GET', '/console/overlay/labnets');
    final device = mine['device'] is Map ? mine['device'] as Map : const {};
    return LabnetInbox(
      enrolled: device['enrolled'] == true,
      machineId: device['machineId'] is String && (device['machineId'] as String).trim().isNotEmpty
          ? device['machineId'] as String : null,
      overlayIp:
          device['overlayIp'] is String ? device['overlayIp'] as String : null,
      invitations: [
        for (final i in _rows(mine['invitations']))
          LabnetInvitation(
            labnetId: _str(i['labnetId']),
            name: _str(i['name']),
            invitedBy: _str(i['invitedBy']),
          ),
      ],
      labnets: [
        for (final l in _rows(theirs['labnets']))
          Labnet(
            id: _str(l['id']),
            name: _str(l['name']),
            fullAccess: l['fullAccess'] == true,
            fleetId: l['fleetId'] is String ? l['fleetId'] as String : null,
            syncPending: l['syncPending'] == true,
            owner: l['editable'] == true,
            members: [
              for (final m in _rows(l['members']))
                LabnetMember(
                  deviceId: _str(m['machineId']),
                  machineName: m['machineName'] is String ? m['machineName'] as String : null,
                  status: _str(m['status']),
                  overlayIp: m['overlayIp'] is String
                      ? m['overlayIp'] as String
                      : null,
                ),
            ],
          ),
      ],
    );
  }

  /// This machine's own half of the inbox, or nothing at all when this process
  /// holds no machine credential.
  ///
  /// A machine with no key is certainly not enrolled and has no invitation
  /// waiting, and the labnets the account manages are still worth showing, so
  /// the one refusal this client makes for itself is not raised. Every answer
  /// the server actually gave is.
  Future<Map<String, dynamic>> _mine() async {
    try {
      return await _machine('GET', '/agent/overlay/inbox');
    } on OverlayBrokerException catch (e) {
      if (e.status == _refusedHere) return const {};
      rethrow;
    }
  }

  /// [fleetId] is required of a caller narrowed to more than one fleet: the
  /// Worker answers 400 "Name the fleet this labnet belongs to." without it
  /// (`src/worker/routes/overlay.ts`).
  Future<Labnet> createLabnet(String name, {String? fleetId}) async {
    final j = await _human('POST', '/console/overlay/labnets', {
      'name': name,
      if (fleetId != null && fleetId.isNotEmpty) 'fleetId': fleetId,
    });
    return Labnet(
        id: '${j['id']}',
        name: '${j['name']}',
        fullAccess: j['fullAccess'] == true,
        fleetId: j['fleetId'] is String ? j['fleetId'] as String : null,
        owner: true);
  }

  Future<void> setFullAccess(String id, bool on) =>
      _human('PATCH', '/console/overlay/labnets/$id', {'fullAccess': on});

  Future<void> renameLabnet(String id, String name) =>
      _human('PATCH', '/console/overlay/labnets/$id', {'name': name});

  Future<void> deleteLabnet(String id) =>
      _human('DELETE', '/console/overlay/labnets/$id');

  /// [machineId] is a `machine.id`, which is what `actor()` resolves the
  /// invited machine against, and it is what [machines] hands the console to
  /// offer. A peer id here is answered "No such machine."
  Future<void> invite(String labnetId, String machineId) => _human('POST',
      '/console/overlay/labnets/$labnetId/invite', {'machine': machineId});

  /// The invited machine decides for itself, which is why this is on the
  /// machine plane: the owner who sent the invitation holds a console
  /// credential, and a console credential answering for a machine is exactly
  /// what plan section 0.4 removes.
  Future<void> decide(String labnetId, {required bool approve}) => _machine(
      'POST', '/agent/overlay/invites/$labnetId/decide', {'approve': approve});

  Future<void> leave(String labnetId) =>
      _machine('POST', '/agent/overlay/labnets/$labnetId/leave', {});

  /// [machineId] is a `machine.id`, the same id the member came back as.
  Future<void> removeMember(String labnetId, String machineId) =>
      _human('DELETE', '/console/overlay/labnets/$labnetId/members/$machineId');
}
