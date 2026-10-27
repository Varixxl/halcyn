import 'package:flutter/material.dart';

import '../theme.dart';

/// Motion for the slate layout: quick enough to read as instant feedback.
abstract final class SlateMotion {
  static const select = Duration(milliseconds: 140);
  static const page = Duration(milliseconds: 180);
}

/// An outlined chip button: filters, toggles, small actions. `selected` fills it.
class Pill extends StatelessWidget {
  const Pill({
    super.key,
    required this.label,
    required this.onPressed,
    this.selected = false,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool selected;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(Palette.r(16));
    // accentDeep, not accent: white text needs the darker blue to stay readable.
    final fill = selected ? Palette.accentDeep : Colors.transparent;
    final color = selected ? Palette.onAccent : Palette.text;
    return AnimatedContainer(
      duration: SlateMotion.select,
      curve: Motion.curve,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: radius,
        border: Border.all(color: selected ? fill : Palette.outline),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onPressed,
          borderRadius: radius,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 34),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 16, color: color),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: color,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A small uppercase heading over a group, e.g. LIBRARY in the sidebar.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 18, 4, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text.toUpperCase(),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.66,
                color: Palette.textMuted,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// One entry in the sidebar. The selected one gets a raised fill and an accent bar on
/// its leading edge.
class SideItem extends StatelessWidget {
  const SideItem({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.count,
    this.onSecondaryTapUp,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  final int? count;
  final GestureTapUpCallback? onSecondaryTapUp;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(Palette.r(16));
    final color = selected ? Palette.text : Palette.textMuted;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: GestureDetector(
        onSecondaryTapUp: onSecondaryTapUp,
        child: AnimatedContainer(
          duration: SlateMotion.select,
          curve: Motion.curve,
          height: 36,
          decoration: BoxDecoration(
            color: selected ? Palette.surfaceHigh : Colors.transparent,
            borderRadius: radius,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onTap,
              borderRadius: radius,
              child: Row(
                children: [
                  AnimatedContainer(
                    duration: SlateMotion.select,
                    curve: Motion.curve,
                    width: 3,
                    height: selected ? 18 : 0,
                    decoration: BoxDecoration(
                      color: Palette.accent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 9),
                  Icon(icon, size: 18, color: color),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        color: color,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                  if (count != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Text(
                        '$count',
                        style: TextStyle(
                          fontSize: 12,
                          color: Palette.textMuted,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Asks for a name, e.g. for a new playlist. Null when cancelled.
Future<String?> askName(
  BuildContext context, {
  required String title,
  required String action,
  String initial = '',
}) {
  return showDialog<String>(
    context: context,
    builder: (context) =>
        _NameDialog(title: title, action: action, initial: initial),
  );
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.title,
    required this.action,
    required this.initial,
  });

  final String title;
  final String action;
  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _name = TextEditingController(text: widget.initial)
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initial.length,
    );

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isNotEmpty) Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Palette.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Palette.r(24)),
        side: BorderSide(color: Palette.outline),
      ),
      title: Text(widget.title),
      content: SizedBox(
        width: 320,
        child: TextField(
          controller: _name,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Name'),
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ListenableBuilder(
          listenable: _name,
          builder: (context, _) => FilledButton(
            onPressed: _name.text.trim().isEmpty ? null : _submit,
            child: Text(widget.action),
          ),
        ),
      ],
    );
  }
}

/// Asks before something that can't be undone. True when confirmed.
Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  required String action,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: Palette.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Palette.r(24)),
        side: BorderSide(color: Palette.outline),
      ),
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(action),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// "Sort: Name ↑" as a pill; its menu picks the key, and picking the current one again
/// reverses it.
class SortPill<K> extends StatelessWidget {
  const SortPill({
    super.key,
    required this.keys,
    required this.label,
    required this.current,
    required this.descending,
    required this.onSelected,
  });

  final List<K> keys;
  final String Function(K) label;
  final K current;
  final bool descending;
  final ValueChanged<K> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<K>(
      tooltip: 'Sort',
      color: Palette.surfaceHigh,
      onSelected: onSelected,
      itemBuilder: (_) => [
        for (final k in keys)
          PopupMenuItem(
            value: k,
            height: 40,
            child: Row(
              children: [
                SizedBox(
                  width: 28,
                  child: k == current
                      ? Icon(
                          descending
                              ? Icons.arrow_downward_rounded
                              : Icons.arrow_upward_rounded,
                          size: 16,
                          color: Palette.accentLight,
                        )
                      : null,
                ),
                Text(label(k)),
              ],
            ),
          ),
      ],
      child: IgnorePointer(
        child: Pill(
          label: 'Sort: ${label(current)}',
          icon: descending
              ? Icons.arrow_downward_rounded
              : Icons.arrow_upward_rounded,
          onPressed: () {},
        ),
      ),
    );
  }
}
