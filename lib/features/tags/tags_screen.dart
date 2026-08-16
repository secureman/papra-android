import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../core/network/models.dart';
import '../../shared/widgets/async_states.dart';
import '../auth/auth_controller.dart';

/// Preset tag colors (Material 700 shades). The fork requires a `color` on
/// tag creation, so the picker always has a selection.
const List<String> _tagPalette = [
  '#e53935', // red
  '#d81b60', // pink
  '#8e24aa', // purple
  '#5e35b1', // deep purple
  '#3949ab', // indigo
  '#1e88e5', // blue
  '#00acc1', // cyan
  '#00897b', // teal
  '#43a047', // green
  '#7cb342', // light green
  '#fdd835', // yellow
  '#fb8c00', // orange
  '#6d4c41', // brown
  '#546e7a', // blue grey
];

Color _hexColor(String hex) {
  final value = hex.replaceFirst('#', '');
  if (value.length == 6) {
    return Color(int.parse('FF$value', radix: 16));
  }
  return Colors.blueGrey;
}

/// Tags tab: manage the organization's tags.
class TagsScreen extends ConsumerStatefulWidget {
  const TagsScreen({super.key});

  @override
  ConsumerState<TagsScreen> createState() => _TagsScreenState();
}

class _TagDraft {
  const _TagDraft({required this.name, required this.color, this.description});

  final String name;
  final String color;
  final String? description;
}

class _TagsScreenState extends ConsumerState<TagsScreen> {
  bool _loading = true;
  String? _error;
  List<PapraTag> _tags = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool showLoader = true}) async {
    final client = ref.read(apiClientProvider);
    if (client == null) {
      setState(() {
        _loading = false;
        _error = null;
        _tags = const [];
      });
      return;
    }
    if (showLoader) setState(() => _loading = true);
    try {
      final tags = await client.listTags();
      if (!mounted) return;
      setState(() {
        _tags = [...tags]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
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

  // ── Actions ───────────────────────────────────────────────────────────────

  Future<void> _showTagDialog({PapraTag? tag}) async {
    final nameController = TextEditingController(text: tag?.name ?? '');
    final descriptionController = TextEditingController(text: tag?.description ?? '');
    var selectedColor = tag?.color ?? _tagPalette.first;

    final draft = await showDialog<_TagDraft>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(tag == null ? 'New tag' : 'Edit tag'),
          // Scrollable so the keyboard never overflows the dialog.
          content: SingleChildScrollView(
            child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Name'),
                onSubmitted: (value) => Navigator.of(context).pop(
                  _TagDraft(name: value.trim(), color: selectedColor, description: descriptionController.text.trim()),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: descriptionController,
                decoration: const InputDecoration(labelText: 'Description (optional)'),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: Text('Color', style: Theme.of(context).textTheme.labelMedium),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final color in _tagPalette)
                    _buildColorDot(
                      color,
                      selected: color == selectedColor,
                      onTap: () => setDialogState(() => selectedColor = color),
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
              onPressed: () => Navigator.of(context).pop(
                _TagDraft(name: nameController.text.trim(), color: selectedColor, description: descriptionController.text.trim()),
              ),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (draft == null || draft.name.isEmpty) return;
    final client = ref.read(apiClientProvider);
    if (client == null) return;
    try {
      if (tag == null) {
        await client.createTag(name: draft.name, color: draft.color, description: draft.description);
      } else {
        await client.updateTag(tag.id, name: draft.name, color: draft.color, description: draft.description);
      }
      _load(showLoader: false);
    } on PapraApiException catch (e) {
      _showSnack(e.message);
    }
  }

  Future<void> _deleteTag(PapraTag tag) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete tag?'),
        content: Text('“${tag.name}” will be removed from all documents.'),
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
    final client = ref.read(apiClientProvider);
    if (client == null) return;
    try {
      await client.deleteTag(tag.id);
      _load(showLoader: false);
    } on PapraApiException catch (e) {
      _showSnack(e.message);
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showTagDialog(),
        icon: const Icon(Icons.sell_outlined),
        label: const Text('New tag'),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const LoadingState(label: 'Loading tags…');
    }
    if (_error != null) {
      return ErrorState(message: _error!, onRetry: () => _load());
    }
    if (_tags.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 160),
          EmptyState(
            icon: Icons.sell_outlined,
            title: 'No tags yet',
            message: 'Create tags to organize your documents.',
            actionLabel: 'Create tag',
            onAction: () => _showTagDialog(),
          ),
        ],
      );
    }

    return RefreshIndicator(
      onRefresh: () => _load(showLoader: false),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          for (final tag in _tags) _buildTagRow(tag),
          const SizedBox(height: 88),
        ],
      ),
    );
  }

  Widget _buildTagRow(PapraTag tag) {
    return ListTile(
      leading: CircleAvatar(
        radius: 16,
        backgroundColor: _hexColor(tag.color),
        child: const Icon(Icons.sell_outlined, size: 16, color: Colors.white),
      ),
      title: Text(tag.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: (tag.description == null || tag.description!.isEmpty)
          ? null
          : Text(tag.description!, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: PopupMenuButton<String>(
        onSelected: (action) {
          switch (action) {
            case 'edit':
              _showTagDialog(tag: tag);
            case 'delete':
              _deleteTag(tag);
          }
        },
        itemBuilder: (context) => const [
          PopupMenuItem(value: 'edit', child: Text('Edit')),
          PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
      onTap: () => _showTagDialog(tag: tag),
    );
  }

  Widget _buildColorDot(String hex, {required bool selected, required VoidCallback onTap}) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: _hexColor(hex),
          shape: BoxShape.circle,
          border: Border.all(
            width: selected ? 3 : 1,
            color: selected ? scheme.onSurface : scheme.outlineVariant,
          ),
        ),
        child: selected
            ? const Icon(Icons.check, size: 18, color: Colors.white)
            : null,
      ),
    );
  }
}
