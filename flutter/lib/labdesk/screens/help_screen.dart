import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/help_content.dart';

/// Searchable user manual using the same theme and accessibility preferences
/// as the console. Reading help never invokes a machine or account operation.
class HelpScreen extends StatefulWidget {
  const HelpScreen({super.key, this.initialTopic = 'fleet'});
  final String initialTopic;

  @override
  State<HelpScreen> createState() => _HelpScreenState();
}

class _HelpScreenState extends State<HelpScreen> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _scroll = ScrollController();
  late String _selected;
  String _query = '';
  HelpTopic get _topic =>
      helpTopics.firstWhere((topic) => topic.id == _selected);

  @override
  void initState() {
    super.initState();
    _selected = helpTopicForContext(widget.initialTopic);
  }

  @override
  void didUpdateWidget(HelpScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialTopic != widget.initialTopic) {
      _selected = helpTopicForContext(widget.initialTopic);
      _search.clear();
      _query = '';
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _choose(String id) => setState(() {
        _selected = id;
        _search.clear();
        _query = '';
        if (_scroll.hasClients) _scroll.jumpTo(0);
      });

  void _clearSearch() => setState(() {
        _search.clear();
        _query = '';
        if (_scroll.hasClients) _scroll.jumpTo(0);
      });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final searching = _query.trim().isNotEmpty;
    final results = searching
        ? searchHelp(_query)
        : [for (final entry in _topic.entries) (topic: _topic, entry: entry)];
    return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyF, control: true):
              _searchFocus.requestFocus,
          const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
              _searchFocus.requestFocus,
          const SingleActivator(LogicalKeyboardKey.escape): _clearSearch,
        },
        child: Focus(
            autofocus: true,
            child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                          key: const ValueKey('help-search'),
                          controller: _search,
                          focusNode: _searchFocus,
                          decoration: InputDecoration(
                              labelText: 'Search Help',
                              hintText: 'Try “stale”, “session”, or “cooldown”',
                              prefixIcon: const Icon(Icons.search),
                              suffixIcon: _query.isEmpty
                                  ? const Tooltip(
                                      message: 'Ctrl+F or Command+F to search',
                                      child: Icon(Icons.keyboard_outlined))
                                  : IconButton(
                                      tooltip: 'Clear search',
                                      onPressed: _clearSearch,
                                      icon: const Icon(Icons.close))),
                          onChanged: (value) => setState(() {
                                _query = value;
                                if (_scroll.hasClients) _scroll.jumpTo(0);
                              })),
                      const SizedBox(height: 16),
                      Expanded(child: LayoutBuilder(builder: (context, c) {
                        final narrow = c.maxWidth < 820 ||
                            MediaQuery.textScalerOf(context).scale(14) > 21;
                        final content = Scrollbar(
                            controller: _scroll,
                            child: ListView.builder(
                                controller: _scroll,
                                key: ValueKey(
                                    'help-content-$_selected-$searching'),
                                padding: const EdgeInsets.only(
                                    right: 12, bottom: 24),
                                itemCount: results.length + 1,
                                itemBuilder: (context, index) {
                                  if (index == 0) {
                                    return Padding(
                                        padding:
                                            const EdgeInsets.only(bottom: 22),
                                        child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Semantics(
                                                  header: true,
                                                  child: Text(
                                                      searching
                                                          ? '${results.length} help results'
                                                          : _topic.title,
                                                      style: theme.textTheme
                                                          .headlineSmall)),
                                              const SizedBox(height: 8),
                                              Text(
                                                  searching
                                                      ? results.isEmpty
                                                          ? 'No matches. Try another term or choose a topic.'
                                                          : 'Results across all topics. Choose a topic to return to its full guide.'
                                                      : _topic.summary,
                                                  style: TextStyle(
                                                      color: theme.colorScheme
                                                          .onSurfaceVariant)),
                                            ]));
                                  }
                                  final result = results[index - 1];
                                  return _entry(context, result.entry,
                                      topic: searching
                                          ? result.topic.title
                                          : null);
                                }));
                        if (narrow) {
                          return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                DropdownButtonFormField<String>(
                                    key: ValueKey('help-topic-$_selected'),
                                    value: _selected,
                                    isExpanded: true,
                                    decoration: const InputDecoration(
                                        labelText: 'Help topic'),
                                    items: [
                                      for (final topic in helpTopics)
                                        DropdownMenuItem(
                                            value: topic.id,
                                            child: Text(topic.title,
                                                maxLines: 1,
                                                overflow:
                                                    TextOverflow.ellipsis))
                                    ],
                                    onChanged: (value) {
                                      if (value != null) _choose(value);
                                    }),
                                const SizedBox(height: 20),
                                Expanded(child: content),
                              ]);
                        }
                        return Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              SizedBox(
                                  width: 216,
                                  child: ListView(children: [
                                    for (final topic in helpTopics)
                                      ListTile(
                                          key: ValueKey(
                                              'help-topic-${topic.id}'),
                                          title: Text(topic.title),
                                          contentPadding:
                                              const EdgeInsets.symmetric(
                                                  horizontal: 8, vertical: 4),
                                          selected: !searching &&
                                              topic.id == _selected,
                                          selectedColor:
                                              theme.colorScheme.primary,
                                          onTap: () => _choose(topic.id))
                                  ])),
                              const VerticalDivider(width: 32),
                              Expanded(child: content),
                            ]);
                      })),
                    ]))));
  }

  Widget _entry(BuildContext context, HelpEntry entry, {String? topic}) {
    final theme = Theme.of(context);
    final reduced = MediaQuery.of(context).disableAnimations;
    return Padding(
        key: ValueKey('help-entry-${entry.id}'),
        padding: const EdgeInsets.only(bottom: 24),
        child: SelectionArea(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
              if (topic != null)
                Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: Text(topic,
                        style: TextStyle(
                            color: theme.colorScheme.primary, fontSize: 12))),
              Semantics(
                  header: true,
                  child: Text(entry.title, style: theme.textTheme.titleLarge)),
              const SizedBox(height: 10),
              Text(entry.meaning, style: const TextStyle(height: 1.6)),
              const SizedBox(height: 14),
              Text('What you can do', style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              Text(entry.action, style: const TextStyle(height: 1.6)),
              const SizedBox(height: 10),
              ExpansionTile(
                  key: ValueKey('help-technical-${entry.id}'),
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 14),
                  expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
                  expansionAnimationStyle: reduced
                      ? AnimationStyle.noAnimation
                      : AnimationStyle(duration: Duration(milliseconds: 180)),
                  title: const Text('Technical details'),
                  children: [
                    Text(entry.technical,
                        style: TextStyle(
                            height: 1.6,
                            color: theme.colorScheme.onSurfaceVariant))
                  ]),
              const Divider(height: 1),
            ])));
  }
}
