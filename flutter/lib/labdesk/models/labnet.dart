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
    this.overlayIp,
  });

  final String deviceId;

  /// `pending` until the machine approves, then `approved`.
  final String status;
  final String? overlayIp;

  bool get approved => status == 'approved';
}

class Labnet {
  const Labnet({
    required this.id,
    required this.name,
    required this.fullAccess,
    required this.owner,
    this.fleetId,
    this.members = const [],
  });

  final String id;
  final String name;

  /// Every port and protocol between members, instead of LabDesk's port and ping.
  final bool fullAccess;

  /// Whether the signed-in account owns it, which is what may change it.
  final bool owner;

  /// The fleet the labnet belongs to, which a caller narrowed to several
  /// fleets has to name when creating one.
  final String? fleetId;
  final List<LabnetMember> members;
}

class LabnetInbox {
  const LabnetInbox({
    this.enrolled = false,
    this.overlayIp,
    this.invitations = const [],
    this.labnets = const [],
  });

  static const empty = LabnetInbox();

  final bool enrolled;
  final String? overlayIp;
  final List<LabnetInvitation> invitations;
  final List<Labnet> labnets;

  static LabnetInbox fromJson(Map<String, dynamic> j) {
    final device = j['device'] is Map ? j['device'] as Map : const {};
    return LabnetInbox(
      enrolled: device['enrolled'] == true,
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
            owner: l['owner'] == true,
            members: [
              for (final m in _list(l['members']))
                LabnetMember(
                  deviceId: _str(m['deviceId']),
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
