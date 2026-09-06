import 'package:flutter/material.dart';
import 'package:url_launcher/link.dart';

/// Displays the review draft; opening or closing it records no acceptance.
Future<void> showLabDeskTerms(BuildContext context) => showDialog<void>(
      context: context,
      builder: (_) => const _TermsDialog(),
    );

class _TermsDialog extends StatefulWidget {
  const _TermsDialog();

  @override
  State<_TermsDialog> createState() => _TermsDialogState();
}

class _TermsDialogState extends State<_TermsDialog> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      child: Semantics(
        namesRoute: true,
        label: 'Terms of Service',
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800, maxHeight: 760),
          child: SizedBox(
            width: 800,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Flexible(
                  child: Scrollbar(
                    controller: _scroll,
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      controller: _scroll,
                      padding: const EdgeInsets.all(20),
                      child: SelectionArea(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(bottom: 16),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text('Terms of Service',
                                            style: theme.textTheme.titleLarge),
                                        const SizedBox(height: 4),
                                        Text('LabDesk · TrapLab Studios',
                                            style: theme.textTheme.bodySmall),
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    autofocus: true,
                                    tooltip: 'Close Terms of Service',
                                    onPressed: () =>
                                        Navigator.of(context).pop(),
                                    icon: const Icon(Icons.close),
                                  ),
                                ],
                              ),
                            ),
                            const Divider(height: 1),
                            const SizedBox(height: 16),
                            Text(_draft,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w600, height: 1.6)),
                            for (final section in _sections) ...[
                              const SizedBox(height: 24),
                              Semantics(
                                header: true,
                                child: Text(section.title,
                                    style: theme.textTheme.titleMedium),
                              ),
                              for (final paragraph in section.paragraphs)
                                Padding(
                                  padding: const EdgeInsets.only(top: 12),
                                  child: Text(paragraph,
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(height: 1.65)),
                                ),
                              if (section == _sections[1]) ...[
                                const SizedBox(height: 8),
                                for (final link in _links)
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: Link(
                                      uri: Uri.parse(link.url),
                                      target: LinkTarget.blank,
                                      builder: (_, followLink) => TextButton(
                                        onPressed: followLink,
                                        child: Text(link.label),
                                      ),
                                    ),
                                  ),
                              ],
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Close'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

const _links = [
  (
    label: 'Read GNU AGPL v3',
    url: 'https://www.gnu.org/licenses/agpl-3.0.html'
  ),
  (
    label: 'View LabDesk source repository',
    url: 'https://github.com/tfdan-cts/LabDesk'
  ),
];

const _draft =
    "Draft for review · September 6, 2026. Operator jurisdiction and public contact "
    "details are awaiting confirmation. This draft is not an active agreement.";

const _sections = <({String title, List<String> paragraphs})>[
  (
    title: "1. About these terms",
    paragraphs: [
      "These Terms describe the conditions for using LabDesk’s hosted services provided "
          "under the name TrapLab Studios (“we,” “us,” or “our”). LabDesk provides remote "
          "machine access, fleet monitoring and management, automation, and managed network "
          "features. Availability depends on the version, platform, configuration, and "
          "permissions in use.",
      "When these Terms are finalized, they apply when you expressly agree to them "
          "through the service or a separate agreement. Viewing this document does not "
          "constitute acceptance. If you act for an organization, you must be authorized to "
          "enter into an agreement on its behalf.",
    ],
  ),
  (
    title: "2. Software licenses remain separate",
    paragraphs: [
      "LabDesk includes open-source software. Rights to use, copy, inspect, modify, and "
          "distribute that software are governed by its applicable licenses, including the "
          "GNU Affero General Public License, version 3, where applicable. These Terms do not "
          "replace those licenses or restrict rights they grant. Required copyright notices, "
          "source-code rights, and third-party license conditions remain in effect.",
      "Hosted-service access is separate from your software license. Suspension or "
          "termination of hosted-service access does not revoke rights independently granted "
          "under an open-source license. Source and license information are available in the "
          "LabDesk source repository and the notices accompanying your version.",
    ],
  ),
  (
    title: "3. Accounts and organizations",
    paragraphs: [
      "Provide accurate account information and protect your credentials, access tokens, "
          "enrollment tokens, and recovery methods. Only give access to people you authorize. "
          "You are responsible for activity performed through credentials and permissions you "
          "control, except to the extent the law provides otherwise.",
      "Organization administrators control membership, machine access, and applicable "
          "policies. Administrators must have authority to make those choices and should "
          "review access when someone changes roles or leaves. Report suspected unauthorized "
          "access promptly and revoke affected credentials where possible.",
    ],
  ),
  (
    title: "4. Authorized remote access",
    paragraphs: [
      "Only enroll, monitor, connect to, or control machines and networks that you own or "
          "have permission to manage. Obtain any consent and provide any notices required for "
          "remote access, monitoring, logging, file transfer, scripts, or other "
          "administrative activity. A technical ability to connect is not proof of "
          "authorization.",
      "You must not use the hosted services to gain unauthorized access; steal "
          "credentials or data; distribute malware; conduct fraud, harassment, or unlawful "
          "surveillance; interfere with other systems; or bypass another person’s access "
          "restrictions. Do not test the security of infrastructure operated by others "
          "without their permission. These restrictions concern misuse of services and "
          "systems, and do not limit lawful research or software-license rights.",
    ],
  ),
  (
    title: "5. Machine actions and automation",
    paragraphs: [
      "Administrative features may run commands, modify services or files, change network "
          "access, or restart or shut down a machine. Review the selected machines, "
          "permissions, scripts, and expected effects before running an action. Maintain "
          "appropriate backups and test automation before using it on important systems.",
      "You remain responsible for the instructions you submit and for ensuring they "
          "comply with your organization’s policies and applicable law. A successful request "
          "or a dashboard indicator does not by itself establish that every intended action "
          "completed.",
    ],
  ),
  (
    title: "6. Monitoring and network information",
    paragraphs: [
      "Machine status, health readings, graphs, and connectivity information depend on "
          "agent reporting and network availability. Information may be delayed, missing, or "
          "stale. Check source timestamps and confirm critical conditions directly when "
          "needed. LabDesk is not a substitute for independent backups, emergency response, "
          "or safety-critical monitoring.",
      "Managed-network access depends on approved membership, configured policy, and "
          "machine readiness. Choosing an organization or viewing a dashboard does not "
          "authorize enrollment or access to another machine. You are responsible for "
          "reviewing the permissions you grant and keeping your endpoint systems secure.",
    ],
  ),
  (
    title: "7. Data and privacy",
    paragraphs: [
      "You retain any rights you hold in data you submit or make available through "
          "LabDesk. You must have permission to provide that data and to authorize its "
          "processing for the requested service. Only provide information necessary for your "
          "use of the application.",
      "Operating remote management features can involve account information, machine "
          "identifiers, system metadata, health readings, job results, and connection or "
          "diagnostic records. The specific data processed depends on the features and "
          "configuration used. Data collection, retention, deletion, and privacy practices "
          "are subject to the applicable Privacy Notice and, where agreed, a data-processing "
          "agreement. A Privacy Notice must accompany the finalized service terms.",
    ],
  ),
  (
    title: "8. Third-party and self-hosted services",
    paragraphs: [
      "Third-party software, identity providers, networks, and infrastructure may be "
          "governed by their own terms and licenses. Your relationship with those providers "
          "is separate. If you self-host LabDesk components, you are responsible for the "
          "infrastructure, configuration, security, and data handling under your control. "
          "TrapLab Studios does not operate your independently hosted environment merely "
          "because it runs LabDesk software.",
    ],
  ),
  (
    title: "9. Fees and service commitments",
    paragraphs: [
      "Any paid offering must disclose its price, billing cycle, renewal conditions, "
          "cancellation process, and applicable refund terms before you purchase it. These "
          "Terms alone do not create a subscription or authorize a charge. Any separately "
          "agreed service-level or support commitment applies according to that agreement; no "
          "such commitment is created by a dashboard or status display.",
    ],
  ),
  (
    title: "10. Availability and changes",
    paragraphs: [
      "Services may be interrupted by maintenance, faults, connectivity problems, or "
          "circumstances outside our control. Features may change as LabDesk develops. We "
          "will provide notice of material service or terms changes where required by law or "
          "an applicable agreement. Material changes must not be used to remove rights that "
          "cannot lawfully be waived.",
    ],
  ),
  (
    title: "11. Suspension and ending use",
    paragraphs: [
      "Hosted-service access may be limited or suspended where reasonably necessary to "
          "address misuse, a security incident, a legal requirement, or a material breach. "
          "Where reasonably possible and legally permitted, we will explain the reason and "
          "provide a way to resolve the issue. Restrictions should be proportionate to the "
          "circumstances.",
      "You may stop using LabDesk. Review and revoke organization access, enrollment "
          "credentials, automation, and network permissions that you no longer need. Removing "
          "a client application does not necessarily remove a separate agent, service, "
          "account, or self-hosted data. Account closure, data deletion, and any paid "
          "cancellation follow their applicable processes and legal requirements.",
    ],
  ),
  (
    title: "12. Warranties and responsibility",
    paragraphs: [
      "Except for express commitments in an applicable agreement and rights that cannot "
          "be excluded by law, services are provided as available without a guarantee of "
          "uninterrupted operation, error-free results, or suitability for a particular "
          "purpose. Software warranties and disclaimers are governed by the applicable "
          "software license.",
      "To the extent permitted by applicable law, neither party is responsible under "
          "these Terms for indirect or consequential loss arising from use of the hosted "
          "services. Nothing in these Terms excludes liability for fraud, willful misconduct, "
          "or any liability or consumer right that applicable law does not permit to be "
          "excluded or limited.",
    ],
  ),
  (
    title: "13. Resolving concerns",
    paragraphs: [
      "We aim to resolve service concerns in good faith. Mandatory consumer protections "
          "and legally available remedies remain unaffected. These draft Terms do not impose "
          "arbitration, a class-action waiver, or an exclusive court venue. Operator "
          "jurisdiction and a monitored public contact address will be supplied before "
          "publication.",
    ],
  ),
  (
    title: "14. General provisions",
    paragraphs: [
      "If a provision is unenforceable, it applies only to the extent lawfully permitted, "
          "and the remaining provisions continue to apply. A failure to enforce a provision "
          "on one occasion does not waive it generally. A separately signed agreement governs "
          "where it expressly conflicts with these Terms. Applicable open-source licenses "
          "control the software rights they grant.",
    ],
  ),
];
