import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/async_states.dart';
import '../../../shared/widgets/tag_chip.dart';
import '../offline_models.dart';
import '../offline_providers.dart';
import 'offline_documents_view.dart';

/// Tags tab of the offline browser: every tag used across the snapshot with
/// its usage count. Tapping a tag slides up a sheet listing that tag's
/// documents — the read-only equivalent of the online Tags tab.
class OfflineTagsView extends ConsumerStatefulWidget {
  const OfflineTagsView({super.key, required this.documents});

  final List<OfflineDocument> documents;

  @override
  ConsumerState<OfflineTagsView> createState() => _OfflineTagsViewState();
}

class _OfflineTagsViewState extends ConsumerState<OfflineTagsView> {
  String? _selectedTagKey;
  Directory? _snapshotDir;

  @override
  void initState() {
    super.initState();
    _resolveSnapshotDir();
  }

  Future<void> _resolveSnapshotDir() async {
    final path = await ref.read(offlineSnapshotStoreProvider).snapshotPath();
    if (!mounted || path == null) return;
    setState(() => _snapshotDir = Directory(path));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tags = aggregateTags(widget.documents).values.toList();

    if (tags.isEmpty) {
      return const EmptyState(
        icon: Icons.sell_outlined,
        title: 'No tags',
        message: 'The imported backup has no tagged documents.',
      );
    }

    final selectedDocs = _selectedTagKey == null
        ? null
        : (widget.documents
            .where((d) => d.tags.any((t) => t.name.toLowerCase() == _selectedTagKey))
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt)));

    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: tags.length,
            itemBuilder: (context, index) {
              final entry = tags[index];
              final isSelected =
                  _selectedTagKey != null && entry.tag.name.toLowerCase() == _selectedTagKey;
              return ListTile(
                leading: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: _hexColor(entry.tag.color).withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                  ),
                  child:
                      Icon(Icons.sell_outlined, size: 18, color: _hexColor(entry.tag.color)),
                ),
                title: Text(entry.tag.name),
                subtitle: Text('${entry.count} document${entry.count == 1 ? '' : 's'}'),
                selected: isSelected,
                trailing: Icon(
                  isSelected ? Icons.close : Icons.chevron_right,
                  color: isSelected ? scheme.primary : null,
                ),
                onTap: () => setState(() {
                  _selectedTagKey =
                      isSelected ? null : entry.tag.name.toLowerCase();
                }),
              );
            },
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          alignment: Alignment.bottomCenter,
          child: selectedDocs == null || _selectedTagKey == null
              ? const SizedBox.shrink()
              : _buildFilteredSheet(scheme, selectedDocs),
        ),
      ],
    );
  }

  Widget _buildFilteredSheet(ColorScheme scheme, List<OfflineDocument> docs) {
    final tag = widget.documents
        .expand((d) => d.tags)
        .firstWhere((t) => t.name.toLowerCase() == _selectedTagKey);
    return Material(
      elevation: 8,
      color: scheme.surface,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.45,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                child: Row(
                  children: [
                    TagChip(tag: tag.asPapraTag()),
                    const SizedBox(width: 8),
                    Text(
                      '${docs.length} document${docs.length == 1 ? '' : 's'}',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Close',
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() => _selectedTagKey = null),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  itemCount: docs.length,
                  itemBuilder: (context, index) => OfflineResolvedDocumentTile(
                    document: docs[index],
                    snapshotDir: _snapshotDir,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Color _hexColor(String hex) {
  final value = hex.replaceFirst('#', '');
  if (value.length == 6) {
    return Color(int.parse('FF$value', radix: 16));
  }
  return Colors.blueGrey;
}
