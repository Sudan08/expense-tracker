import 'dart:ui' show TextDirection;

import 'package:flutter/material.dart' hide TextDirection;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../../core/money.dart';
import '../../transactions/transactions_controller.dart';
import '../../transactions/widgets/txn_tile.dart';
import '../daily_spend_controller.dart';

const _cellSize = 12.0;
const _cellGap = 3.0;
const _monthLabelHeight = 16.0;

/// A GitHub-contributions-style grid of the last year of spend, one square
/// per day. Design choices, and why, are in docs/APP_IMPROVEMENTS.md
/// section 3.1 -- the short version:
///
/// - Colour buckets are quartiles of non-zero spend days, not a linear
///   scale, because personal spend is heavy-tailed (one rent payment would
///   otherwise be the only visible square all year).
/// - "No data yet" and "an unresolved ledger gap" are rendered distinctly
///   from "covered, genuinely zero spend" -- conflating them would make the
///   graph lie by omission exactly where the pipeline is least sure of
///   itself.
/// - The ramp is a single neutral hue (indigo), never green -- more
///   spending is not an achievement.
class SpendHeatmap extends ConsumerStatefulWidget {
  const SpendHeatmap({super.key});

  @override
  ConsumerState<SpendHeatmap> createState() => _SpendHeatmapState();
}

class _SpendHeatmapState extends ConsumerState<SpendHeatmap> {
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    // Open scrolled to the most recent (rightmost) column, not the oldest.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _openDay(HeatmapDay day) async {
    await showModalBottomSheet<void>(
      context: context,
      // Root navigator, not the branch one. StatefulShellRoute nests each
      // branch's Navigator *inside* the shell Scaffold's body, so a sheet
      // pushed on the nearest Navigator paints under the Scaffold's own FAB
      // and bottom nav -- the Add button floated on top of the sheet and the
      // barrier dimmed only the list. A modal belongs above app chrome
      // wherever it was launched from.
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (context) => _DayDetailSheet(day: day),
    );
  }

  @override
  Widget build(BuildContext context) {
    final daysAsync = ref.watch(heatmapDaysProvider);

    if (daysAsync.hasError) {
      return Text('Could not load the spend graph: ${daysAsync.error}');
    }
    final days = daysAsync.value;
    if (days == null) {
      return const SizedBox(
        height: 7 * (_cellSize + _cellGap) + _monthLabelHeight,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (days.isEmpty) {
      return const Text('No data yet.');
    }

    // Week columns, Sunday first (GitHub's own convention -- familiar shape
    // beats a "more correct" Monday start for this specific widget).
    final firstDay = days.first.day;
    final leadingBlanks = (firstDay.weekday % 7); // Dart: Mon=1..Sun=7 -> Sun=0
    final weeks = <List<HeatmapDay?>>[];
    var currentWeek = List<HeatmapDay?>.filled(7, null);
    var col = leadingBlanks;
    for (final day in days) {
      currentWeek[col % 7] = day;
      col++;
      if (col % 7 == 0) {
        weeks.add(currentWeek);
        currentWeek = List<HeatmapDay?>.filled(7, null);
      }
    }
    if (col % 7 != 0) weeks.add(currentWeek);

    final width = weeks.length * (_cellSize + _cellGap);
    const height = 7 * (_cellSize + _cellGap) + _monthLabelHeight;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          controller: _scrollController,
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: width,
            height: height,
            child: GestureDetector(
              onTapUp: (details) {
                final weekIndex = (details.localPosition.dx / (_cellSize + _cellGap)).floor();
                final rowIndex =
                    ((details.localPosition.dy - _monthLabelHeight) / (_cellSize + _cellGap)).floor();
                if (weekIndex < 0 || weekIndex >= weeks.length || rowIndex < 0 || rowIndex > 6) return;
                final day = weeks[weekIndex][rowIndex];
                if (day != null) _openDay(day);
              },
              child: CustomPaint(
                painter: _HeatmapPainter(
                  weeks: weeks,
                  isDark: Theme.of(context).brightness == Brightness.dark,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        const _Legend(),
      ],
    );
  }
}

class _HeatmapPainter extends CustomPainter {
  _HeatmapPainter({required this.weeks, required this.isDark});
  final List<List<HeatmapDay?>> weeks;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    String? lastMonthLabel;

    for (var w = 0; w < weeks.length; w++) {
      final x = w * (_cellSize + _cellGap);

      final firstRealDay = weeks[w].firstWhere((d) => d != null, orElse: () => null);
      if (firstRealDay != null && firstRealDay.day.day <= 7) {
        final label = DateFormat.MMM().format(firstRealDay.day);
        if (label != lastMonthLabel) {
          textPainter.text = TextSpan(
            text: label,
            style: TextStyle(
              fontSize: 10,
              color: isDark ? Colors.white60 : Colors.black45,
            ),
          );
          textPainter.layout();
          textPainter.paint(canvas, Offset(x, 0));
          lastMonthLabel = label;
        }
      }

      for (var r = 0; r < 7; r++) {
        final day = weeks[w][r];
        final y = _monthLabelHeight + r * (_cellSize + _cellGap);
        final rect = RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, _cellSize, _cellSize),
          const Radius.circular(3),
        );
        final paint = Paint()..color = _colorFor(day, isDark);
        canvas.drawRRect(rect, paint);

        if (day?.kind == HeatmapDayKind.uncertainGap) {
          _drawHatch(canvas, Rect.fromLTWH(x, y, _cellSize, _cellSize), isDark);
        }
      }
    }
  }

  void _drawHatch(Canvas canvas, Rect rect, bool isDark) {
    final paint = Paint()
      ..color = isDark ? Colors.white38 : Colors.black38
      ..strokeWidth = 1;
    canvas.drawLine(rect.topLeft, rect.bottomRight, paint);
  }

  Color _colorFor(HeatmapDay? day, bool isDark) {
    if (day == null || day.kind == HeatmapDayKind.beforeData) {
      return Colors.transparent;
    }
    if (day.kind == HeatmapDayKind.uncertainGap) {
      return isDark ? const Color(0xFF3A3A3A) : const Color(0xFFE0E0E0);
    }
    // Single-hue indigo ramp, never green -- more spending isn't a win.
    // Bucket 0 is a bordered "covered, nothing spent" square.
    switch (day.bucket) {
      case 0:
        return isDark ? const Color(0xFF232733) : const Color(0xFFEDEFF5);
      case 1:
        return isDark ? const Color(0xFF3A3F7A) : const Color(0xFFC6CBF0);
      case 2:
        return isDark ? const Color(0xFF4B52A8) : const Color(0xFF9CA5E8);
      case 3:
        return isDark ? const Color(0xFF5C64D6) : const Color(0xFF6B76D9);
      case 4:
      default:
        return isDark ? const Color(0xFF7E87FF) : const Color(0xFF454FC2);
    }
  }

  @override
  bool shouldRepaint(covariant _HeatmapPainter oldDelegate) =>
      oldDelegate.weeks != weeks || oldDelegate.isDark != isDark;
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final painter = _HeatmapPainter(weeks: const [], isDark: isDark);
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _swatch(painter._colorFor(HeatmapDay(day: DateTime.now(), kind: HeatmapDayKind.spend, spentPaisa: 0, bucket: 0), isDark), 'No spend'),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Less', style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(width: 4),
            for (final b in [1, 2, 3, 4])
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1),
                child: Container(
                  width: _cellSize,
                  height: _cellSize,
                  decoration: BoxDecoration(
                    color: painter._colorFor(
                      HeatmapDay(day: DateTime.now(), kind: HeatmapDayKind.spend, spentPaisa: 1, bucket: b),
                      isDark,
                    ),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            const SizedBox(width: 4),
            Text('More', style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
        _swatch(
          painter._colorFor(HeatmapDay(day: DateTime.now(), kind: HeatmapDayKind.uncertainGap, spentPaisa: 0, bucket: 0), isDark),
          'Uncertain (ledger gap)',
          hatched: true,
        ),
      ],
    );
  }

  Widget _swatch(Color color, String label, {bool hatched = false}) {
    return Builder(builder: (context) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: _cellSize,
            height: _cellSize,
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
            child: hatched
                ? CustomPaint(painter: _HatchPainter(Theme.of(context).brightness == Brightness.dark))
                : null,
          ),
          const SizedBox(width: 4),
          Text(label, style: Theme.of(context).textTheme.labelSmall),
        ],
      );
    });
  }
}

class _HatchPainter extends CustomPainter {
  _HatchPainter(this.isDark);
  final bool isDark;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = isDark ? Colors.white38 : Colors.black38
      ..strokeWidth = 1;
    canvas.drawLine(Offset.zero, Offset(size.width, size.height), paint);
  }

  @override
  bool shouldRepaint(covariant _HatchPainter oldDelegate) => false;
}

class _DayDetailSheet extends ConsumerWidget {
  const _DayDetailSheet({required this.day});
  final HeatmapDay day;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final txns = ref.watch(transactionsByDateProvider(day.day));
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(DateFormat.yMMMd().format(day.day), style: Theme.of(context).textTheme.titleMedium),
                  if (day.kind == HeatmapDayKind.spend)
                    Text(formatPaisa(day.spentPaisa), style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
            ),
            if (day.kind == HeatmapDayKind.uncertainGap)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  'This day falls inside an unresolved ledger gap -- the pipeline '
                  'detected a balance jump here with no matching transaction. '
                  'Check Data health from the app bar menu.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 8),
            Flexible(
              child: txns.when(
                data: (rows) => rows.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('No transactions this day.'),
                      )
                    : ListView(
                        shrinkWrap: true,
                        children: [
                          for (final t in rows)
                            TxnTile(txn: t, onTap: () => context.push('/transactions/${t.id}')),
                        ],
                      ),
                // A bare Center here would expand to fill all the height
                // isScrollControlled hands this Flexible (the full screen),
                // so the sheet opens full-screen while loading and then
                // snaps down, unanimated, the instant the day's rows arrive.
                // A fixed-height spinner keeps the sheet compact throughout.
                loading: () => const SizedBox(
                  height: 96,
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (e, _) => Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('Could not load: $e'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
