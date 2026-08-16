import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../core/network/models.dart';
import '../../shared/widgets/async_states.dart';
import '../auth/auth_controller.dart';

const _fieldOptions = [
  ('name', 'Document name'),
  ('content', 'Document content'),
];

const _operatorOptions = [
  ('equal', 'equals'),
  ('not_equal', 'does not equal'),
  ('contains', 'contains'),
  ('not_contains', 'does not contain'),
  ('starts_with', 'starts with'),
  ('ends_with', 'ends with'),
];

const _maxConditions = 10;

String _fieldLabel(String field) =>
    _fieldOptions.firstWhere((o) => o.$1 == field, orElse: () => ('', field)).$2;

String _operatorLabel(String operator) =>
    _operatorOptions.firstWhere((o) => o.$1 == operator, orElse: () => ('', operator)).$2;

Color _hexTagColor(String hex) {
  final value = hex.replaceFirst('#', '');
  if (value.length == 6) {
    return Color(int.parse('FF$value', radix: 16));
  }
  return Colors.blueGrey;
}

/// Tagging rules screen.
///
/// A rule automatically tags documents whose conditions match (all/any).
/// Supports creating/editing rules (name, description, match mode, up to 10
/// conditions, target tags), toggling them on/off, applying a rule to
/// existing documents in the background, and deleting rules.
class TaggingRulesScreen extends ConsumerStatefulWidget {
  const TaggingRulesScreen({super.key});

  @override
  ConsumerState<TaggingRulesScreen> createState() => _TaggingRulesScreenState();
}

class _TaggingRulesScreenState extends ConsumerState<TaggingRulesScreen> {
  List<PapraTaggingRule> _rules = const [];
  List<PapraTag> _tags = const [];
  bool _loading = true;
  String? _error;

  Map<String, String> get _tagNames => {for (final t in _tags) t.id: t.name};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final client = ref.read(apiClientProvider);
    if (client == null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'You are not signed in.';
      });
      return;
    }
    setState(() => _loading = true);
    try {
      final results = await Future.wait([client.listTaggingRules(), client.listTags()]);
      if (!mounted) return;
      setState(() {
        _rules = results[0] as List<PapraTaggingRule>;
        _tags = results[1] as List<PapraTag>;
        _loading = false;
        _error = null;
      });
    } on PapraApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Something went wrong. Please try again.';
      });
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  Future<void> _createRule() async {
    final client = ref.read(apiClientProvider);
    if (client == null) return;

    final draft = await showDialog<_RuleDraft>(
      context: context,
      builder: (context) => _RuleEditorDialog(tags: _tags),
    );
    if (draft == null || !mounted) return;

    try {
      await client.createTaggingRule(
        name: draft.name,
        description: draft.description,
        enabled: draft.enabled,
        conditionMatchMode: draft.conditionMatchMode,
        conditions: draft.conditions,
        tagIds: draft.tagIds,
      );
      _showSnack('Rule created.');
      _load();
    } on PapraApiException catch (e) {
      _showSnack(e.message);
    }
  }

  Future<void> _editRule(PapraTaggingRule rule) async {
    final client = ref.read(apiClientProvider);
    if (client == null) return;

    final draft = await showDialog<_RuleDraft>(
      context: context,
      builder: (context) => _RuleEditorDialog(tags: _tags, rule: rule),
    );
    if (draft == null || !mounted) return;

    try {
      await client.updateTaggingRule(
        rule.id,
        name: draft.name,
        description: draft.description,
        enabled: draft.enabled,
        conditionMatchMode: draft.conditionMatchMode,
        conditions: draft.conditions,
        tagIds: draft.tagIds,
      );
      _showSnack('Rule updated.');
      _load();
    } on PapraApiException catch (e) {
      _showSnack(e.message);
    }
  }

  Future<void> _toggleEnabled(PapraTaggingRule rule) async {
    final client = ref.read(apiClientProvider);
    if (client == null) return;
    try {
      await client.updateTaggingRule(rule.id, enabled: !rule.enabled);
      _load();
    } on PapraApiException catch (e) {
      _showSnack(e.message);
    }
  }

  Future<void> _applyToExisting(PapraTaggingRule rule) async {
    final client = ref.read(apiClientProvider);
    if (client == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Apply to existing documents?'),
        content: Text('“${rule.name}” will be applied to every document in '
            'the organization. This runs in the background and may take '
            'a while.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await client.applyTaggingRuleToExisting(rule.id);
      _showSnack('Tagging started in the background.');
    } on PapraApiException catch (e) {
      _showSnack(e.message);
    }
  }

  Future<void> _deleteRule(PapraTaggingRule rule) async {
    final client = ref.read(apiClientProvider);
    if (client == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete tagging rule?'),
        content: Text('“${rule.name}” will be removed. Documents already '
            'tagged by it keep their tags.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await client.deleteTaggingRule(rule.id);
      _showSnack('Rule deleted.');
      _load();
    } on PapraApiException catch (e) {
      _showSnack(e.message);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Reload whenever the authenticated client changes (org switch, re-login).
    ref.listen(apiClientProvider, (previous, next) {
      if (previous != next) _load();
    });

    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Tagging rules')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createRule,
        icon: const Icon(Icons.add),
        label: const Text('New rule'),
      ),
      body: _loading
          ? const LoadingState(label: 'Loading tagging rules…')
          : _error != null
              ? ErrorState(message: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: _rules.isEmpty
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: const [
                            SizedBox(height: 160),
                            EmptyState(
                              icon: Icons.rule,
                              title: 'No tagging rules yet',
                              message: 'Rules automatically tag documents '
                                  'when their conditions match.',
                            ),
                          ],
                        )
                      : ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.all(16),
                          children: [
                            for (final rule in _rules) _buildRuleTile(rule, scheme),
                          ],
                        ),
                ),
    );
  }

  Widget _buildRuleTile(PapraTaggingRule rule, ColorScheme scheme) {
    final tagNames = rule.tagIds.map((id) => _tagNames[id] ?? id).join(', ');

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: rule.enabled
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          child: Icon(
            Icons.rule,
            color: rule.enabled
                ? scheme.onPrimaryContainer
                : scheme.onSurfaceVariant,
          ),
        ),
        title: Text(
          rule.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: rule.enabled
              ? null
              : TextStyle(color: scheme.onSurfaceVariant),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (rule.description != null && rule.description!.isNotEmpty)
              Text(rule.description!, maxLines: 2, overflow: TextOverflow.ellipsis),
            Text(_conditionsSummary(rule)),
            Text(
              'Tags: $tagNames',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(value: rule.enabled, onChanged: (_) => _toggleEnabled(rule)),
            PopupMenuButton<String>(
              onSelected: (action) {
                switch (action) {
                  case 'edit':
                    _editRule(rule);
                  case 'apply':
                    _applyToExisting(rule);
                  case 'delete':
                    _deleteRule(rule);
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'edit', child: Text('Edit')),
                PopupMenuItem(value: 'apply', child: Text('Apply to existing documents')),
                PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _conditionsSummary(PapraTaggingRule rule) {
    if (rule.conditions.isEmpty) {
      return 'No conditions (applies to every document)';
    }
    final mode = rule.conditionMatchMode == 'any' ? 'Any' : 'All';
    final parts = rule.conditions
        .map((c) => '${_fieldLabel(c.field)} ${_operatorLabel(c.operator)} '
            '“${c.value}”')
        .toList();
    return '$mode of: ${parts.join('; ')}';
  }
}

/// Result of the rule editor dialog.
class _RuleDraft {
  const _RuleDraft({
    required this.name,
    this.description,
    required this.enabled,
    required this.conditionMatchMode,
    required this.conditions,
    required this.tagIds,
  });

  final String name;
  final String? description;
  final bool enabled;
  final String conditionMatchMode;
  final List<PapraTaggingCondition> conditions;
  final List<String> tagIds;
}

/// A mutable condition row inside the editor.
class _ConditionDraft {
  _ConditionDraft({required this.id, this.field = 'name', this.operator = 'contains', this.value = ''});

  final int id;
  String field;
  String operator;
  String value;
}

/// Create/edit dialog for a tagging rule: name, description, match mode,
/// dynamic condition rows and a tag multi-select.
class _RuleEditorDialog extends StatefulWidget {
  const _RuleEditorDialog({required this.tags, this.rule});

  final List<PapraTag> tags;
  final PapraTaggingRule? rule;

  @override
  State<_RuleEditorDialog> createState() => _RuleEditorDialogState();
}

class _RuleEditorDialogState extends State<_RuleEditorDialog> {
  static int _nextConditionId = 0;

  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late bool _enabled;
  late String _matchMode;
  late List<_ConditionDraft> _conditions;
  late Set<String> _selectedTagIds;
  String? _error;

  bool get _isEditing => widget.rule != null;

  @override
  void initState() {
    super.initState();
    final rule = widget.rule;
    _nameController = TextEditingController(text: rule?.name ?? '');
    _descriptionController = TextEditingController(text: rule?.description ?? '');
    _enabled = rule?.enabled ?? true;
    _matchMode = rule?.conditionMatchMode ?? 'all';
    _conditions = (rule?.conditions ?? const <PapraTaggingCondition>[])
        .map((c) => _ConditionDraft(
              id: _nextConditionId++,
              field: c.field,
              operator: c.operator,
              value: c.value,
            ))
        .toList();
    _selectedTagIds = {...?rule?.tagIds};
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  _RuleDraft? _buildDraft() {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter a rule name.');
      return null;
    }
    if (_selectedTagIds.isEmpty) {
      setState(() => _error = 'Select at least one tag.');
      return null;
    }
    for (final condition in _conditions) {
      if (condition.value.trim().isEmpty) {
        setState(() => _error = 'Fill in a value for every condition.');
        return null;
      }
    }
    return _RuleDraft(
      name: name,
      description: _descriptionController.text.trim().isEmpty
          ? null
          : _descriptionController.text.trim(),
      enabled: _enabled,
      conditionMatchMode: _matchMode,
      conditions: [
        for (final c in _conditions)
          PapraTaggingCondition(
            field: c.field,
            operator: c.operator,
            value: c.value.trim(),
          ),
      ],
      tagIds: _selectedTagIds.toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEditing ? 'Edit tagging rule' : 'New tagging rule'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_error != null) ...[
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _nameController,
              maxLength: 64,
              decoration: const InputDecoration(labelText: 'Name', counterText: ''),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _descriptionController,
              maxLength: 256,
              maxLines: 2,
              decoration: const InputDecoration(labelText: 'Description (optional)', counterText: ''),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Enabled'),
              value: _enabled,
              onChanged: (v) => setState(() => _enabled = v),
            ),
            const SizedBox(height: 8),
            Text('Match conditions when…', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'all', label: Text('All'), icon: Icon(Icons.done_all)),
                ButtonSegment(value: 'any', label: Text('Any'), icon: Icon(Icons.add_circle_outline)),
              ],
              selected: {_matchMode},
              onSelectionChanged: (selection) =>
                  setState(() => _matchMode = selection.first),
            ),
            const SizedBox(height: 16),
            Text('Conditions', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 8),
            if (_conditions.isEmpty)
              Text(
                'No conditions — the rule applies to every document.',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              )
            else
              for (final condition in _conditions)
                _buildConditionCard(condition),
            if (_conditions.length < _maxConditions) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() {
                    _conditions.add(_ConditionDraft(id: _nextConditionId++));
                  }),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add condition'),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Text('Apply tags', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 8),
            if (widget.tags.isEmpty)
              Text(
                'No tags yet — create one in the Tags tab first.',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              )
            else
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final tag in widget.tags)
                    FilterChip(
                      avatar: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: _hexTagColor(tag.color),
                          shape: BoxShape.circle,
                        ),
                      ),
                      label: Text(tag.name),
                      selected: _selectedTagIds.contains(tag.id),
                      onSelected: (selected) => setState(() {
                        if (selected) {
                          _selectedTagIds.add(tag.id);
                        } else {
                          _selectedTagIds.remove(tag.id);
                        }
                      }),
                    ),
                ],
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final draft = _buildDraft();
            if (draft != null) Navigator.of(context).pop(draft);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }

  Widget _buildConditionCard(_ConditionDraft condition) {
    return Card(
      key: ValueKey(condition.id),
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: DropdownButtonFormField<String>(
                    initialValue: condition.field,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Field', isDense: true),
                    items: [
                      for (final (value, label) in _fieldOptions)
                        DropdownMenuItem(value: value, child: Text(label)),
                    ],
                    onChanged: (value) => setState(() {
                      if (value != null) condition.field = value;
                    }),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 4,
                  child: DropdownButtonFormField<String>(
                    initialValue: condition.operator,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Condition', isDense: true),
                    items: [
                      for (final (value, label) in _operatorOptions)
                        DropdownMenuItem(value: value, child: Text(label)),
                    ],
                    onChanged: (value) => setState(() {
                      if (value != null) condition.operator = value;
                    }),
                  ),
                ),
                IconButton(
                  tooltip: 'Remove condition',
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: () => setState(() {
                    _conditions.removeWhere((c) => c.id == condition.id);
                  }),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextFormField(
                initialValue: condition.value,
                onChanged: (value) => condition.value = value,
                decoration: const InputDecoration(
                  labelText: 'Value',
                  isDense: true,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
