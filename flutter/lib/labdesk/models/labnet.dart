/// What lab-desk.net tells a machine about labnets: the invitations waiting
/// for a decision on this machine, and the labnets it owns or belongs to.
class LabnetInvitation {
  const LabnetInvitation({
    required this.labnetId,
    required this.name,
    required this.invitedBy,
  });

  final String labnetId;
  final String name;

  /// The account that asked, as an email address.
  final String invitedBy;
}

class LabnetMember {
  const LabnetMember({
    required this.deviceId,
    required this.status,
    this.machineName,
    this.overlayIp,
  });

  final String deviceId;
  final String? machineName;

  /// `pending` until approved; `leaving`/`removing` await network confirmation.
  final String status;
  final String? overlayIp;

  bool get approved => status == 'approved';
  bool get removalPending => status == 'leaving' || status == 'removing';
}

class Labnet {
  const Labnet({
    required this.id,
    required this.name,
    required this.fullAccess,
    required this.owner,
    this.fleetId,
    this.syncPending = false,
    this.members = const [],
  });

  final String id;
  final String name;

  /// Every port and protocol between members, instead of LabDesk's port and ping.
  final bool fullAccess;

  /// Whether the server permits this account to manage this Labnet.
  final bool owner;

  /// The fleet the labnet belongs to, which a caller narrowed to several
  /// fleets has to name when creating one.
  final String? fleetId;
  final bool syncPending;
  final List<LabnetMember> members;
}

class LabnetInbox {
  const LabnetInbox({
    this.enrolled = false,
    this.machineId,
    this.overlayIp,
    this.invitations = const [],
    this.labnets = const [],
  });

  static const empty = LabnetInbox();

  final bool enrolled;
  /// Canonical local identity supplied by the signed machine inbox only.
  final String? machineId;
  final String? overlayIp;
  final List<LabnetInvitation> invitations;
  final List<Labnet> labnets;

  /// Acknowledged pending and completed removals supersede cached membership.
  LabnetInbox withRemovalResults(Map<(String, String), String> results) {
    if (results.isEmpty) return this;
    Labnet reconcile(Labnet labnet) {
      bool completed(LabnetMember member) =>
          switch (results[(labnet.id, member.deviceId)]) {
            'left' || 'removed' => true,
            _ => false,
          };
      final members = [
        for (final member in labnet.members)
          if (!completed(member))
            LabnetMember(
              deviceId: member.deviceId,
              machineName: member.machineName,
              status: results[(labnet.id, member.deviceId)] ?? member.status,
              overlayIp: member.overlayIp,
            ),
      ];
      return Labnet(
        id: labnet.id,
        name: labnet.name,
        fullAccess: labnet.fullAccess,
        owner: labnet.owner,
        fleetId: labnet.fleetId,
        syncPending: labnet.syncPending ||
            members.any((member) => member.removalPending),
        members: members,
      );
    }
    return LabnetInbox(
      enrolled: enrolled,
      machineId: machineId,
      overlayIp: overlayIp,
      invitations: invitations,
      labnets: labnets.map(reconcile).toList(),
    );
  }

  static LabnetInbox fromJson(Map<String, dynamic> j) {
    final device = j['device'] is Map ? j['device'] as Map : const {};
    return LabnetInbox(
      enrolled: device['enrolled'] == true,
      machineId: device['machineId'] is String && (device['machineId'] as String).trim().isNotEmpty
          ? device['machineId'] as String : null,
      overlayIp: device['overlayIp'] is String ? device['overlayIp'] as String : null,
      invitations: [
        for (final i in _list(j['invitations']))
          LabnetInvitation(
            labnetId: _str(i['labnetId']),
            name: _str(i['name']),
            invitedBy: _str(i['invitedBy']),
          ),
      ],
      labnets: [
        for (final l in _list(j['labnets']))
          Labnet(
            id: _str(l['id']),
            name: _str(l['name']),
            fullAccess: l['fullAccess'] == true,
            fleetId: l['fleetId'] is String ? l['fleetId'] as String : null,
            syncPending: l['syncPending'] == true,
            owner: l['owner'] == true,
            members: [
              for (final m in _list(l['members']))
                LabnetMember(
                  deviceId: _str(m['deviceId']),
                  machineName: m['machineName'] is String ? m['machineName'] as String : null,
                  status: _str(m['status']),
                  overlayIp: m['overlayIp'] is String ? m['overlayIp'] as String : null,
                ),
            ],
          ),
      ],
    );
  }

  static List<Map> _list(Object? v) =>
      v is List ? v.whereType<Map>().toList() : const [];
  static String _str(Object? v) => v is String ? v : '';
}
