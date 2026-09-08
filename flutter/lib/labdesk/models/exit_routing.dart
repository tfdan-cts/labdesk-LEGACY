class ExitRouteReadback {
  const ExitRouteReadback({required this.id, required this.selected, required this.isExit});
  final String id;
  final bool selected;
  final bool isExit;
  factory ExitRouteReadback.fromJson(Map<String, dynamic> json) => ExitRouteReadback(
    id: json['id'] is String ? json['id'] as String : '',
    selected: json['selected'] == true,
    isExit: json['isExit'] == true,
  );
}

class ExitRoutingReadback {
  const ExitRoutingReadback({this.routes = const [], this.status = 'unknown', this.error, this.selectionSupported = false, this.hostingSupported = false, this.subnetSharingSupported = false, this.exitLanSupported = false, this.exitIsolationActive = false, this.allowExitLan = true, this.clientLocalLanSupported = false, this.localLanBlocked = false, this.appliedExitId, this.revision});
  final List<ExitRouteReadback> routes;
  final String status;
  final String? error;
  final bool selectionSupported;
  final bool hostingSupported;
  final bool subnetSharingSupported;
  final bool exitLanSupported;
  final bool exitIsolationActive;
  final bool allowExitLan;
  final bool clientLocalLanSupported;
  final bool localLanBlocked;
  final String? appliedExitId;
  final int? revision;
  factory ExitRoutingReadback.fromJson(Map<String, dynamic> json) => ExitRoutingReadback(
    routes: (json['routes'] is List ? json['routes'] as List : const []).whereType<Map<String, dynamic>>().map(ExitRouteReadback.fromJson).toList(),
    status: json['status'] is String ? json['status'] as String : 'unknown',
    error: json['error'] is String ? json['error'] as String : null,
    selectionSupported: json['selectionSupported'] == true,
    hostingSupported: json['hostingSupported'] == true,
    subnetSharingSupported: json['subnetSharingSupported'] == true,
    exitLanSupported: json['exitLanSupported'] == true,
    exitIsolationActive: json['exitIsolationActive'] == true,
    allowExitLan: json['allowExitLan'] != false,
    clientLocalLanSupported: json['clientLocalLanSupported'] == true,
    localLanBlocked: json['localLanBlocked'] == true,
    appliedExitId: json['appliedExitId'] is String ? json['appliedExitId'] as String : null,
    revision: json['revision'] is int ? json['revision'] as int : null,
  );
}
