import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../services/iphone_duo_service.dart';

/// Installs iPhone Duo awareness for everything below it. Place it once, in
/// `MaterialApp.builder`.
///
/// It does two things:
///
/// * exposes the live [IPhoneDuoInfo] so `IPhoneDuoService.postureOf` /
///   `foldOf` rebuild their callers when the hinge moves;
/// * while the phone is half folded, publishes the fold as a hinge
///   [ui.DisplayFeature] on `MediaQuery`. Flutter then keeps dialogs, bottom
///   sheets and popup menus on one side of the fold by itself.
///
/// On every other device, and on a Duo that is closed or flat, it adds
/// nothing.
class DuoScope extends StatelessWidget {
  final Widget child;

  const DuoScope({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<IPhoneDuoInfo>(
      valueListenable: IPhoneDuoService.listenable,
      child: child,
      builder: (context, info, child) {
        Widget result = child!;
        if (info.isDuo) {
          final mq = MediaQuery.of(context);
          final fold = info.foldFor(mq.size);
          if (fold != null) {
            result = MediaQuery(
              data: mq.copyWith(
                displayFeatures: [
                  ...mq.displayFeatures,
                  ui.DisplayFeature(
                    bounds: fold.band,
                    type: ui.DisplayFeatureType.hinge,
                    state: ui.DisplayFeatureState.postureHalfOpened,
                  ),
                ],
              ),
              child: result,
            );
          }
        }
        return DuoInheritedInfo(info: info, child: result);
      },
    );
  }
}

/// The fold band expressed in the coordinates of one widget.
@immutable
class DuoLocalFold {
  /// The band relative to the widget's top-left corner. It can lie partly or
  /// wholly outside the widget; check [intersects].
  final Rect band;
  final Axis axis;

  /// The size of the widget the band is relative to.
  final Size size;

  const DuoLocalFold({required this.band, required this.axis, required this.size});

  bool get isBook => axis == Axis.vertical;
  bool get isTabletop => axis == Axis.horizontal;

  /// Whether the band actually crosses the widget, leaving usable room on
  /// both sides of it.
  bool get intersects {
    if (axis == Axis.vertical) {
      return band.left > 0 && band.right < size.width;
    }
    return band.top > 0 && band.bottom < size.height;
  }

  /// Book: x where the left half ends. Tabletop: y where the upper half ends.
  double get start => axis == Axis.vertical ? band.left : band.top;

  /// Book: x where the right half begins. Tabletop: y where the lower half
  /// begins.
  double get end => axis == Axis.vertical ? band.right : band.bottom;

  @override
  bool operator ==(Object other) =>
      other is DuoLocalFold &&
      other.band == band &&
      other.axis == axis &&
      other.size == size;

  @override
  int get hashCode => Object.hash(band, axis, size);
}

/// Builds with the fold band translated into this widget's own coordinates.
///
/// `fold` is null whenever the phone is not half folded, so the common path is
/// a plain pass-through:
///
/// ```dart
/// DuoFoldBuilder(
///   builder: (context, fold) => GridView.builder(
///     gridDelegate: DuoSpineGridDelegate(base: delegate, fold: fold),
///     ...
///   ),
/// )
/// ```
///
/// While folded, the widget fills the available width (book) or height
/// (tabletop), so use it around content that already expands along that axis
/// (scroll views, `Expanded` children, full-width rows).
class DuoFoldBuilder extends StatefulWidget {
  final Widget Function(BuildContext context, DuoLocalFold? fold) builder;

  const DuoFoldBuilder({super.key, required this.builder});

  @override
  State<DuoFoldBuilder> createState() => _DuoFoldBuilderState();
}

class _DuoFoldBuilderState extends State<DuoFoldBuilder> {
  Offset? _origin;
  Size? _size;
  bool _measureScheduled = false;

  // The fold the measurement was taken for, and the one currently in effect.
  // A measurement from another pose or view size is never reused.
  DuoFold? _measuredFor;
  DuoFold? _currentFold;

  // Keeps the State below the builder (scroll offsets, text fields) alive
  // when the wrappers around it appear and disappear with the fold.
  final GlobalKey _subtreeKey = GlobalKey();

  void _scheduleMeasure() {
    if (_measureScheduled) return;
    _measureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureScheduled = false;
      if (!mounted) return;
      final box = context.findRenderObject();
      if (box is! RenderBox || !box.hasSize || !box.attached) return;
      // Measured against the enclosing route, not the view: a route that is
      // covered or mid-transition is translated on iOS, and that offset must
      // not leak into the fold position.
      final routeBox = ModalRoute.of(context)?.subtreeContext?.findRenderObject();
      final origin = box.localToGlobal(
        Offset.zero,
        ancestor: routeBox is RenderBox && routeBox.attached ? routeBox : null,
      );
      final size = box.size;
      final moved = _measuredFor != _currentFold ||
          _origin == null ||
          (origin - _origin!).distance > 0.5 ||
          _size == null ||
          (size.width - _size!.width).abs() > 0.5 ||
          (size.height - _size!.height).abs() > 0.5;
      if (moved) {
        setState(() {
          _origin = origin;
          _size = size;
          _measuredFor = _currentFold;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final fold = IPhoneDuoService.foldOf(context);
    if (fold == null) {
      _origin = null;
      _size = null;
      _measuredFor = null;
      _currentFold = null;
      return KeyedSubtree(key: _subtreeKey, child: widget.builder(context, null));
    }
    // The position can change without a rebuild of this widget (a sibling
    // resizing), so it is re-measured after every build while folded.
    _currentFold = fold;
    if (_measuredFor != fold) {
      _origin = null;
      _size = null;
    }
    _scheduleMeasure();
    DuoLocalFold? local;
    final origin = _origin;
    final size = _size;
    if (origin != null && size != null) {
      local = DuoLocalFold(
        band: fold.band.shift(-origin),
        axis: fold.axis,
        size: size,
      );
    }
    // Fill the axis the fold crosses, so the measured box is the available
    // area and does not shift when the builder's output changes size.
    final axis = fold.axis;
    return LayoutBuilder(
      builder: (context, constraints) {
        final child = KeyedSubtree(
          key: _subtreeKey,
          child: widget.builder(context, local),
        );
        if (axis == Axis.vertical && constraints.hasBoundedWidth) {
          return SizedBox(width: constraints.maxWidth, child: child);
        }
        if (axis == Axis.horizontal && constraints.hasBoundedHeight) {
          return SizedBox(height: constraints.maxHeight, child: child);
        }
        return child;
      },
    );
  }
}

/// Keeps a block of fixed content (titles, button rows, forms) out of the
/// fold while the phone is half folded.
///
/// * Book: the child is confined to one side of the spine, chosen by [side].
/// * Tabletop: the child is confined to the upper or lower half.
///
/// When not half folded, or when the fold does not cross this widget, the
/// child is laid out untouched. Like [DuoFoldBuilder] it fills its
/// constraints while folded, so wrap content that already expands.
class DuoAvoidFold extends StatefulWidget {
  final Widget child;

  /// Which side of the fold to keep the child on.
  final DuoFoldSide side;

  /// Whether to avoid the horizontal band in tabletop too. Scrolling content
  /// may pass through the fold, so this is usually wanted only for fixed
  /// controls.
  final bool avoidTabletop;

  const DuoAvoidFold({
    super.key,
    required this.child,
    this.side = DuoFoldSide.leading,
    this.avoidTabletop = false,
  });

  @override
  State<DuoAvoidFold> createState() => _DuoAvoidFoldState();
}

class _DuoAvoidFoldState extends State<DuoAvoidFold> {
  static const double minExtent = 72.0;

  // The child keeps its State while the padding around it comes and goes.
  final GlobalKey _childKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final child = KeyedSubtree(key: _childKey, child: widget.child);
    final fold = IPhoneDuoService.foldOf(context);
    if (fold == null) return child;
    if (fold.isTabletop && !widget.avoidTabletop) return child;
    // An enclosing DuoAvoidFold already keeps this subtree on one side of the
    // same fold; padding again from a not-yet-updated measurement would
    // squeeze the child for a frame.
    final confined = _DuoConfinement.maybeOf(context);
    if (confined == fold.axis) return child;
    return DuoFoldBuilder(
      builder: (context, fold) {
        if (fold == null || !fold.intersects) return child;
        // A side too small to be useful is not worth confining to: use the
        // other one, or leave the child alone.
        final total = fold.isBook ? fold.size.width : fold.size.height;
        final leadingRoom = fold.start;
        final trailingRoom = total - fold.end;
        var side = widget.side;
        final room = side == DuoFoldSide.leading ? leadingRoom : trailingRoom;
        final otherRoom =
            side == DuoFoldSide.leading ? trailingRoom : leadingRoom;
        if (room < minExtent) {
          if (otherRoom < minExtent) return child;
          side = side == DuoFoldSide.leading
              ? DuoFoldSide.trailing
              : DuoFoldSide.leading;
        }
        final EdgeInsets padding;
        if (fold.isBook) {
          padding = side == DuoFoldSide.leading
              ? EdgeInsets.only(right: fold.size.width - fold.start)
              : EdgeInsets.only(left: fold.end);
        } else {
          padding = side == DuoFoldSide.leading
              ? EdgeInsets.only(bottom: fold.size.height - fold.start)
              : EdgeInsets.only(top: fold.end);
        }
        return _DuoConfinement(
          axis: fold.axis,
          child: Padding(padding: padding, child: child),
        );
      },
    );
  }
}

/// Marks a subtree that a [DuoAvoidFold] is confining to one side of the
/// fold along [axis].
class _DuoConfinement extends InheritedWidget {
  final Axis axis;

  const _DuoConfinement({required this.axis, required super.child});

  static Axis? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_DuoConfinement>()?.axis;

  @override
  bool updateShouldNotify(_DuoConfinement oldWidget) => oldWidget.axis != axis;
}

/// Leading is the left half in book and the upper half in tabletop.
enum DuoFoldSide { leading, trailing }

/// Wraps a regular grid delegate so that, in book posture, no tile straddles
/// the spine: columns are laid out on either side of it with the fold band
/// left empty in between.
///
/// With `fold == null` (the normal case) it behaves exactly like [base].
///
/// [crossAxisInset] is the distance from the left edge of the widget the fold
/// was measured against (the [DuoFoldBuilder]) to the left edge of the grid's
/// tiles, typically the grid's left padding.
class DuoSpineGridDelegate extends SliverGridDelegate {
  final SliverGridDelegate base;
  final DuoLocalFold? fold;
  final double crossAxisInset;

  /// Tiles are never made narrower than this; if a side cannot fit one, the
  /// base layout is used unchanged.
  final double minTileWidth;

  const DuoSpineGridDelegate({
    required this.base,
    required this.fold,
    this.crossAxisInset = 0,
    this.minTileWidth = 72,
  });

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final baseLayout = base.getLayout(constraints);
    final f = fold;
    if (f == null || !f.isBook) return baseLayout;
    if (constraints.axis != Axis.vertical) return baseLayout;
    if (baseLayout is! SliverGridRegularTileLayout) return baseLayout;

    final extent = constraints.crossAxisExtent;
    final gapStart = f.start - crossAxisInset;
    final gapEnd = f.end - crossAxisInset;
    if (gapStart <= 0 || gapEnd >= extent) return baseLayout;

    final spacing =
        math.max(0.0, baseLayout.crossAxisStride - baseLayout.childCrossAxisExtent);
    final mainSpacing =
        math.max(0.0, baseLayout.mainAxisStride - baseLayout.childMainAxisExtent);
    final baseTile = baseLayout.childCrossAxisExtent;
    if (baseTile <= 0) return baseLayout;

    final leftWidth = gapStart;
    final rightWidth = extent - gapEnd;

    int columnsFor(double width) =>
        math.max(1, ((width + spacing) / (baseTile + spacing)).round());

    final leftCount = columnsFor(leftWidth);
    final rightCount = columnsFor(rightWidth);
    final leftTile = (leftWidth - spacing * (leftCount - 1)) / leftCount;
    final rightTile = (rightWidth - spacing * (rightCount - 1)) / rightCount;
    final tile = math.min(leftTile, rightTile);
    if (tile < minTileWidth) return baseLayout;

    final aspect = baseLayout.childMainAxisExtent / baseTile;
    final tileMain = tile * aspect;

    final offsets = <double>[
      for (var i = 0; i < leftCount; i++) i * (tile + spacing),
      for (var i = 0; i < rightCount; i++) gapEnd + i * (tile + spacing),
    ];

    return _DuoSpineGridLayout(
      columnOffsets: offsets,
      childCrossAxisExtent: tile,
      childMainAxisExtent: tileMain,
      mainAxisStride: tileMain + mainSpacing,
      crossAxisExtent: extent,
      reverseCrossAxis: axisDirectionIsReversed(constraints.crossAxisDirection),
    );
  }

  @override
  bool shouldRelayout(DuoSpineGridDelegate oldDelegate) {
    return oldDelegate.fold != fold ||
        oldDelegate.crossAxisInset != crossAxisInset ||
        oldDelegate.minTileWidth != minTileWidth ||
        oldDelegate.base.runtimeType != base.runtimeType ||
        base.shouldRelayout(oldDelegate.base);
  }
}

class _DuoSpineGridLayout extends SliverGridLayout {
  final List<double> columnOffsets;
  final double childCrossAxisExtent;
  final double childMainAxisExtent;
  final double mainAxisStride;
  final double crossAxisExtent;
  final bool reverseCrossAxis;

  const _DuoSpineGridLayout({
    required this.columnOffsets,
    required this.childCrossAxisExtent,
    required this.childMainAxisExtent,
    required this.mainAxisStride,
    required this.crossAxisExtent,
    required this.reverseCrossAxis,
  });

  int get _columns => columnOffsets.length;

  @override
  int getMinChildIndexForScrollOffset(double scrollOffset) {
    if (mainAxisStride <= 0) return 0;
    return _columns * (scrollOffset ~/ mainAxisStride);
  }

  @override
  int getMaxChildIndexForScrollOffset(double scrollOffset) {
    if (mainAxisStride <= 0) return 0;
    final rows = (scrollOffset / mainAxisStride).ceil();
    return math.max(0, _columns * rows - 1);
  }

  @override
  SliverGridGeometry getGeometryForChildIndex(int index) {
    final column = index % _columns;
    final row = index ~/ _columns;
    var cross = columnOffsets[column];
    if (reverseCrossAxis) {
      cross = crossAxisExtent - cross - childCrossAxisExtent;
    }
    return SliverGridGeometry(
      scrollOffset: row * mainAxisStride,
      crossAxisOffset: cross,
      mainAxisExtent: childMainAxisExtent,
      crossAxisExtent: childCrossAxisExtent,
    );
  }

  @override
  double computeMaxScrollOffset(int childCount) {
    if (childCount == 0) return 0;
    final rows = ((childCount - 1) ~/ _columns) + 1;
    final spacing = mainAxisStride - childMainAxisExtent;
    return mainAxisStride * rows - spacing;
  }
}
