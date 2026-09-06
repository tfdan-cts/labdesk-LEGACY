/// An authenticated membership offered by the service, never a server profile.
class OrganizationSummary {
  const OrganizationSummary(
      {required this.id, required this.name, required this.role});

  final String id;
  final String name;
  final String role;

  static OrganizationSummary? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['orgId'], name = value['name'], role = value['role'];
    if (id is! String ||
        id.trim().isEmpty ||
        id.contains(RegExp(r'[\r\n]')) ||
        id.length > 128 ||
        name is! String ||
        name.trim().isEmpty ||
        name.length > 256 ||
        role is! String ||
        role.length > 64) return null;
    return OrganizationSummary(id: id, name: name, role: role);
  }
}

class OrganizationDirectory {
  const OrganizationDirectory(
      {required this.userId, required this.organizations});
  final String userId;
  final List<OrganizationSummary> organizations;
}
