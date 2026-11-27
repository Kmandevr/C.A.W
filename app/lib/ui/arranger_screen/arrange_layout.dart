// Arrange's layout: the main view with the focus panel, the toolbar, the clip bar, the zoom bar, the settings panel and the timeline.
// ignore_for_file: invalid_use_of_protected_member
part of '../arranger_screen.dart';

extension _ArrangeLayout on _ArrangerScreenState {
  Widget _main(BuildContext context) {
    final s = widget.state;
    final p = s.project;
    final focused = p.layers.where((l) => l.id == _focusId && !l.isFolder).firstOrNull;
    if (focused != null) {
      _closing = null;
      _shownFocus = focused;
    } else if (_shownFocus != null) {
      final d = EditMotion.scaled(Motion.of(context), EditMotionKind.panels, Motion.panel);
      if (d != null && p.layers.contains(_shownFocus)) {
        _closing = _shownFocus;
        _panelOut.duration = d;
        _panelOut.reverse(from: 1);
      }
      _shownFocus = null;
    }
    // Files opened an audio file's sample editor: the Clip tab.
    if (_sections?.takeClipTab() ?? false) _tab = FocusTab.clip;
    // The panel's track: the focused one, or the one whose panel is leaving.
    final shownTrack = focused ?? _closing;
    final layout = focusLayoutFor(MediaQuery.sizeOf(context));
    final callbacks = _callbacks(_patterns);
    final focusable = _focusable;
    final fi = focused == null ? -1 : focusable.indexOf(focused);
    Widget panel(bool sheet) => FocusPanel(
      state: s, layer: shownTrack!, tab: _tab, bottomSheetStyle: sheet,
      onTab: (t) => setState(() => _tab = t),
      onClose: () { _panelHigh = false; _focus(null); },
      expanded: _panelHigh,
      onExpand: sheet ? (v) => setState(() => _panelHigh = v) : null,
      onPrevious: fi > 0 ? () => _step(-1) : null,
      onNext: fi >= 0 && fi < focusable.length - 1 ? () => _step(1) : null,
      onOpenModule: widget.onOpenModule,
      browsing: _browser,
      onBrowse: () => setState(() => _browser = !_browser),
    );

    // On its way out the panel slides and fades back where it came from, and takes no touches.
    Widget leaving(Widget panel, Offset to) => _closing == null ? panel : IgnorePointer(child: FadeTransition(
      opacity: CurvedAnimation(parent: _panelOut, curve: Curves.easeOutCubic),
      child: Motion.of(context) != MotionLevel.full ? panel : SlideTransition(
        position: Tween(begin: to, end: Offset.zero).animate(CurvedAnimation(parent: _panelOut, curve: Curves.easeOutCubic)),
        child: panel)));
    final Widget body;
    if (shownTrack != null && layout == FocusLayout.pinned) {
      // Phone portrait: the track pinned at the top (still scrollable and editable), its panel below.
      // Opened higher, the panel slides up over the track and leaves only a sliver of it.
      body = LayoutBuilder(builder: (context, box) {
        final pinnedH = (box.maxHeight * 0.2).clamp(84.0, 220.0).toDouble();
        return Column(children: [
          AnimatedContainer(duration: Motion.move(Motion.panel, Motion.of(context)), curve: Curves.easeOutCubic,
            height: _panelHigh ? 0 : pinnedH + 4,
            child: ClipRect(child: OverflowBox(alignment: Alignment.topCenter, minHeight: pinnedH + 4, maxHeight: pinnedH + 4,
              child: Column(children: [
                SizedBox(height: pinnedH, child: _timeline(context, [shownTrack], callbacks, pinned: true)),
                const SizedBox(height: 4),
              ])))),
          Expanded(child: leaving(SlideIn(from: const Offset(0, 0.12), child: panel(true)), const Offset(0, 0.12))),
        ]);
      });
    } else if (shownTrack != null) {
      // Landscape and desktop: a right side panel; the tracks keep their full height.
      // Its size is FocusSidePane's (focus_panel.dart): resizable on a phone, two thirds by default.
      body = FocusSidePane(settings: s.settings, desktop: MediaQuery.sizeOf(context).width >= 900,
        tracks: _arrangement(context, callbacks), panel: leaving(panel(false), const Offset(0.15, 0)));
    } else {
      body = _arrangement(context, callbacks);
    }

    // The Files pane leaves as it came: its room stays while it slides out (owner, 2026-11-11).
    if (_browserWas && !_browser) {
      final d = EditMotion.scaled(Motion.of(context), EditMotionKind.panels, Motion.panel);
      if (d != null) {
        _browserLeaving = true;
        _browserTimer?.cancel();
        _browserTimer = Timer(d, () { if (mounted) setState(() => _browserLeaving = false); });
      }
    }
    if (_browser) _browserLeaving = false;
    _browserWas = _browser;
    final paneRoom = _browser || _browserLeaving;
    final withBrowser = LayoutBuilder(builder: (context, box) {
      // The same Files browser as Build's explorer; hold an item and drag it onto a track or the FX stack.
      final pane = Presence(
        from: box.maxWidth >= 600 ? const Offset(0.15, 0) : const Offset(0, 0.15),
        child: !_browser ? null : Padding(padding: const EdgeInsets.all(4), child: GlassPanel(key: const ValueKey('arrange-browser'),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SizedBox(height: 30, child: Row(children: [
              const SizedBox(width: 10),
              const Icon(Icons.drag_indicator, size: 14, color: Neon.dim),
              const SizedBox(width: 4),
              const Expanded(child: Text('Hold an item, drag it onto a track', maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Neon.dim, fontSize: 11))),
              IconButton(tooltip: 'Close the browser', iconSize: 16, visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _browser = false), icon: const Icon(Icons.close)),
            ])),
            Expanded(child: FileManagerScreen(key: const ValueKey('arrange explorer'), state: s, explorer: true,
              onOpenAsset: (_) {})),
          ]))));
      if (box.maxWidth >= 600) {
        return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(child: body),
          if (paneRoom) SizedBox(width: math.min(300.0, box.maxWidth * 0.32), child: pane),
        ]);
      }
      return Column(children: [
        Expanded(child: body),
        if (paneRoom) SizedBox(height: math.max(160.0, box.maxHeight * 0.4), child: pane),
      ]);
    });

    return PopScope(
      // Android Back closes the browser, then leaves the focus view (owner, 2026-11-09).
      canPop: focused == null && !_browser,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_browser) {
          setState(() => _browser = false);
        } else if (focused != null) {
          _focus(null);
        }
      },
      child: Column(children: [
        // The toolbar tucks away with the status row while the tracks scroll down (owner, 2026-11-10).
        _tucked(Column(mainAxisSize: MainAxisSize.min, children: [
          _toolbar(context, focused),
          AnimatedSize(duration: Motion.move(Motion.standard, Motion.of(context)), curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: Presence(from: const Offset(0, -0.3), child: zoomBar ? _zoomBar() : null)),
        ])),
        if (settings) _settingsPanel(),
        Expanded(child: _withDockedClipBar(withBrowser, focused)),
      ]),
    );
  }

  /// A phone (a narrow arrangement) gets the clip bar docked near the bottom of the tracks while clips are selected,
  /// in reach of the thumb; a wide one has it in the toolbar.
  Widget _withDockedClipBar(Widget body, LayerDoc? focused) {
    final s = widget.state;
    if (focused != null || mixerCard || (s.selectedClipIds.isEmpty && !_selectMode)) return body;
    return LayoutBuilder(builder: (context, box) {
      if (box.maxWidth >= 760) return body;
      return Stack(children: [
        Positioned.fill(child: body),
        Positioned(left: 8, right: 8, bottom: 10, child: Center(child: SlideIn(from: const Offset(0, 0.4),
          child: FittedBox(fit: BoxFit.scaleDown, child: _clipBar(docked: true))))),
      ]);
    });
  }

  Widget _toolbar(BuildContext context, LayerDoc? focused) {
    final s = widget.state;
    final p = s.project;
    final gap = s.settings.trackGap;
    final clipsChosen = s.selectedClipIds.isNotEmpty || _selectMode;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
      child: LayoutBuilder(builder: (context, constraints) {
        // A phone gets one row of icon buttons that scrolls sideways, instead of two rows of labelled buttons
        // under a heading (owner, 2026-11-05: one toolbar row, as in the UI plan).
        final narrow = constraints.maxWidth < 760;
        final controls = <Widget>[
          // Long-press (or right-click) for the add-track menu: a folder and the track templates.
          Builder(builder: (context) => GestureDetector(
            onSecondaryTapUp: (d) => showAddTrackMenu(context, s, d.globalPosition),
            child: narrow
              // The tooltip shows on hover only: a long press opens the add-track menu.
              ? Tooltip(message: _addTrackTip, triggerMode: TooltipTriggerMode.manual,
                  child: TextButton(key: const ValueKey('arrange-add-track'), onPressed: s.addLayer,
                    onLongPress: () => showAddTrackMenu(context, s, menuAnchorOf(context)),
                    style: TextButton.styleFrom(minimumSize: const Size(48, 48), shape: const CircleBorder()),
                    child: const Icon(Icons.add, color: Neon.green)))
              // A desktop's hover names the menu behind it (a finger's long press shows no tooltip).
              : Tooltip(message: _addTrackTip, triggerMode: TooltipTriggerMode.manual,
                  child: TextButton.icon(key: const ValueKey('arrange-add-track'), onPressed: s.addLayer,
                  onLongPress: () => showAddTrackMenu(context, s, menuAnchorOf(context)),
                  icon: const Icon(Icons.add, size: 17), label: const Text('Track'))))),
          IconButton(key: const ValueKey('arrange-browse'), onPressed: () => setState(() => _browser = !_browser),
            color: _browser ? Neon.blue : Neon.dim, icon: const Icon(Icons.folder_open),
            tooltip: 'Files: drag one onto a track'),
          // REAPER's repeat (R): loops playback over the loop range drawn on the ruler, or the whole song when off.
          IconButton(key: const ValueKey('arrange-loop'), onPressed: s.toggleLoopRange,
            color: p.loopsRange ? Neon.blue : Neon.dim, icon: const Icon(Icons.repeat),
            tooltip: p.loopsRange ? 'Loop range on (R): drag on the ruler to change it' : 'Loop range (R): drag on the ruler to set it'),
          IconButton(onPressed: () => setState(() => zoomBar = !zoomBar),
            key: const ValueKey('arrange-zoom'),
            color: zoomBar ? Neon.blue : null,
            icon: const Icon(Icons.zoom_in), tooltip: 'Zoom (or pinch; Ctrl + wheel)'),
          PopupMenuButton<String>(
            tooltip: 'Track height',
            onSelected: (v) {
              final px = double.parse(v.substring(2));
              if (v.startsWith('h:')) {
                s.settings.update((x) => x.trackHeight = px).then((_) { if (mounted) setState(() {}); });
              } else {
                s.settings.update((x) => x.trackGap = px).then((_) { if (mounted) setState(() {}); });
              }
            },
            icon: const Icon(Icons.height, color: Neon.dim),
            itemBuilder: (_) => [
              for (final (px, name) in const [(44.0, 'Thin'), (60.0, 'Compact'), (76.0, 'Standard'), (96.0, 'Tall'), (120.0, 'Extra tall')])
                CheckedPopupMenuItem(value: 'h:$px', checked: _trackHeight == px, child: Text('$name · ${px.round()} px')),
              const PopupMenuDivider(),
              for (final (px, name) in const [(0.0, 'No gap'), (3.0, 'Small gap'), (6.0, 'Gap'), (12.0, 'Wide gap'), (20.0, 'Extra wide gap')])
                CheckedPopupMenuItem(value: 'g:$px', checked: gap == px, child: Text(px == 0 ? name : '$name · ${px.round()} px')),
            ],
          ),
          Tooltip(message: 'Grid: clips snap to this', child: DropdownButton<int>(key: const ValueKey('arrange-snap'),
            value: s.arrangementSnapSteps, underline: const SizedBox.shrink(),
            items: [for (final v in [1, 2, 4, 8, 16]) DropdownMenuItem(value: v, child: Text('1/${v == 1 ? 16 : 16 ~/ v}'))],
            onChanged: (v) { if (v != null) setState(() => s.arrangementSnapSteps = v); })),
          if (narrow)
            IconButton(onPressed: s.addFolder,
              icon: const Icon(Icons.create_new_folder_outlined), color: Neon.green, tooltip: 'Add folder')
          else
            TextButton.icon(onPressed: s.addFolder,
              icon: const Icon(Icons.create_new_folder_outlined, size: 17), label: const Text('Folder')),
          // The mixer opens as a card over the tracks: the master and every track's strip (the Mixer workspace
          // folded into Arrange, #139).
          IconButton(key: const ValueKey('arrange-mixer'), onPressed: () => setState(() => mixerCard = !mixerCard),
            color: mixerCard ? Neon.blue : Neon.dim, icon: const Icon(Icons.tune), tooltip: 'Mixer'),
          IconButton(onPressed: () => setState(() => settings = !settings),
            color: settings ? Neon.blue : Neon.dim, icon: const Icon(Icons.settings_outlined), tooltip: 'Settings'),
          IconButton(onPressed: () => setState(() { cardsView = true; mixerCard = false; }),
            icon: const Icon(Icons.view_agenda_outlined), tooltip: 'Track cards'),
        ];
        if (narrow) {
          // The row scrolls; a fade at an edge says there is more past it (Mixer, Settings, Track cards).
          return ScrollFade(child: SingleChildScrollView(
            key: const ValueKey('arrange-toolbar'),
            scrollDirection: Axis.horizontal,
            child: Row(children: controls),
          ));
        }
        // Wide: the clip bar sits in the toolbar while clips are selected (owner, 2026-11-10: docs/reaper-flow.md).
        return Row(children: [
          const Text('ARRANGEMENT', style: TextStyle(
            color: Neon.dim, fontSize: 11, letterSpacing: 1.5, fontWeight: FontWeight.w800)),
          const SizedBox(width: 8),
          Expanded(child: Align(alignment: Alignment.centerLeft, child: !clipsChosen ? const SizedBox.shrink()
              : SingleChildScrollView(scrollDirection: Axis.horizontal, child: _clipBar(docked: false)))),
          // The controls scroll sideways when the toolbar is just over the phone width.
          ConstrainedBox(constraints: BoxConstraints(maxWidth: math.max(0.0, constraints.maxWidth - 170)),
            child: SingleChildScrollView(scrollDirection: Axis.horizontal, reverse: true,
              child: Row(mainAxisSize: MainAxisSize.min, children: controls))),
        ]);
      }),
    );
  }

  Widget _clipBar({required bool docked}) => ClipBar(state: widget.state, docked: docked, selectMode: _selectMode,
    onSelectMode: (v) => setState(() => _selectMode = v),
    onProperties: () => showClipProperties(context, widget.state));

  Widget _tucked(Widget bar) {
    final shown = _sections?.barsShown;
    if (shown == null) return bar;
    return ValueListenableBuilder<bool>(valueListenable: shown,
      builder: (context, v, child) => TuckAway(shown: v || settings, child: child!), child: bar);
  }

  /// Time and height zoom: − and + glide a step, the sliders follow the finger (time on a log scale).
  Widget _zoomBar() {
    final ratio = math.log(_ArrangerScreenState.maxZoom / _ArrangerScreenState.minZoom);
    final h = _trackHeight;
    Widget icon(IconData i, String tip, VoidCallback onTap) => IconButton(onPressed: onTap, tooltip: tip,
        visualDensity: VisualDensity.compact, iconSize: 18, icon: Icon(i, color: Neon.dim));
    return SizedBox(height: 36, child: Row(key: const ValueKey('arrange-zoom-bar'), children: [
      const SizedBox(width: 6),
      const Tooltip(message: 'Time zoom', child: Icon(Icons.swap_horiz, size: 16, color: Neon.dim)),
      icon(Icons.remove, 'Zoom out', () => _animateViewTo(zoom: _zoomAim / 1.4)),
      // It follows the zoom as it changes (a pinch, a glide), which doesn't build the screen again.
      Expanded(flex: 3, child: ResetOnDoubleTap(onReset: () => _animateViewTo(zoom: 18),
        child: ValueListenableBuilder<double>(valueListenable: _zoomN, builder: (context, zoom, _) => Slider(
          key: const ValueKey('arrange-zoom-time'),
          value: (math.log(zoom / _ArrangerScreenState.minZoom) / ratio).clamp(0.0, 1.0).toDouble(),
          onChanged: (v) { _glide.stop(); _setZoom(_ArrangerScreenState.minZoom * math.exp(v * ratio)); })))),
      icon(Icons.add, 'Zoom in', () => _animateViewTo(zoom: _zoomAim * 1.4)),
      IconButton(key: const ValueKey('arrange-zoom-fit'), onPressed: _zoomToFit, tooltip: 'Zoom to fit the song',
        visualDensity: VisualDensity.compact, iconSize: 18, icon: const Icon(Icons.fit_screen, color: Neon.dim)),
      const SizedBox(width: 6),
      const Tooltip(message: 'Track height', child: Icon(Icons.swap_vert, size: 16, color: Neon.dim)),
      Expanded(flex: 2, child: ResetOnDoubleTap(onReset: () {
        widget.state.settings.update((x) => x.trackHeight = 0).then((_) { if (mounted) setState(() {}); });
      }, child: Slider(key: const ValueKey('arrange-zoom-height'),
        value: h.clamp(Settings.minTrackHeight, Settings.maxTrackHeight).toDouble(),
        min: Settings.minTrackHeight, max: Settings.maxTrackHeight,
        onChanged: (v) => setState(() => _dragTrackH = v),
        onChangeEnd: (_) => _saveHeaderSize()))),
    ]));
  }

  Widget _settingsPanel() {
    final s = widget.state;
    return Flexible(flex: 0, child: ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.5),
      child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(10, 0, 10, 8), child: Column(children: [
        ProjectSettingsSheet(state: s),
        // This project's: a moved clip takes the points of its track's lanes over it along (#230).
        Padding(padding: const EdgeInsets.only(top: 6), child: Row(children: [
          const Expanded(child: Text('Automation follows clips', style: TextStyle(color: Neon.dim))),
          Switch(key: const ValueKey('automation-follows-clips'), value: s.project.automationFollowsClips,
            onChanged: (v) {
              s.endUndoStep();
              s.editProject((p) => p.automationFollowsClips = v);
              s.endUndoStep();
              setState(() {});
            }),
        ])),
        // App-wide: how long-press menus open (owner: a list near the finger by default, a ring as a setting).
        Padding(padding: const EdgeInsets.only(top: 6), child: Row(children: [
          const Expanded(child: Text('Long-press menus', style: TextStyle(color: Neon.dim))),
          SegmentedButton<LongPressMenuStyle>(
            key: const ValueKey('menu-style'),
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(value: LongPressMenuStyle.list, icon: Icon(Icons.list, size: 18), tooltip: 'List near the finger'),
              ButtonSegment(value: LongPressMenuStyle.ring, icon: Icon(Icons.donut_large, size: 18), tooltip: 'Ring'),
            ],
            selected: {s.settings.longPressMenu},
            onSelectionChanged: (v) => s.settings.update((x) => x.longPressMenu = v.first)
                .then((_) { if (mounted) setState(() {}); }),
          ),
        ])),
      ])),
    ));
  }

  Widget _timeline(BuildContext context, List<LayerDoc> layers, _TrackCallbacks callbacks, {bool pinned = false}) {
    final s = widget.state;
    final p = s.project;
    _stepWN.scale = _zoomScale;
    final trackHeight = _trackHeight;
    // The gap between tracks (Settings, chosen from the track height menu), so tracks don't sit on each other.
    final gap = pinned ? 0.0 : s.settings.trackGap;
    final headW = _headerWidth;
    final gen = _buildGen;
    // What depends on the zoom builds from [zoomed] at the pixels per step of the moment: a zoom frame builds these
    // parts again and nothing around them.
    Widget zoomed(Widget Function(double stepW) build) =>
        ValueListenableBuilder<double>(valueListenable: _stepWN, builder: (context, w, _) => build(w));
    // The song ends at its last clip or automation point (or the shortest length) and playback loops back there,
    // as in Reaper. The timeline always reaches 64 bars past it, so a clip can go anywhere and the song grows with it.
    final end = p.engineLoopSteps;
    // A few screens past the furthest of the song's end, the playhead and where the view has been: it never meets a
    // wall on the right (owner, 2026-11-11).
    final screenW = MediaQuery.sizeOf(context).width;
    double widthAt(double stepW) {
      final screens = 3 * screenW / stepW;
      final reach = math.max(math.max(p.timelineSteps.toDouble(), end + 64.0 * p.stepsPerBar),
          math.max(s.playheadStep, _reachSteps) + screens);
      return math.max(560.0, math.min(p.maxArrangementSteps.toDouble(), reach) * stepW);
    }
    // Over the lanes (#207): the section bar, the ruler (bar numbers, signature flags, the loop range) and, once the
    // tempo changes, the tempo lane, which grows in and out. Taller on a phone, for a finger.
    final sectionH = _phone ? 24.0 : 22.0, rulerH = _phone ? 28.0 : 24.0;
    final tempoTarget = !pinned && p.tempoMap.length > 1 ? tempoLaneHeight(_phone) : 0.0;
    final focusId = _focusId;
    final drag = pinned ? null : _drag;
    // The rows' total height, so the New track zone fills the rest of the view below the last track.
    // Each track's own row height (owner, 2026-11-11): its own height or the default, compact or thin.
    double rowH(LayerDoc l) => pinned ? trackHeight : _rowHeight(l);
    // A row's height glides to a new one (a collapse, a folder, the height menu; owner, 2026-11-11), in the lengths
    // edit-motion kind; the header and its lane glide together, and only they rebuild while it runs. A drag follows
    // the finger at once.
    final rowGlide = pinned || _dragTrackH != null || _rowDragId != null || EditMotion.fadeOnly(context) ? Duration.zero
        : EditMotion.of(context, EditMotionKind.lengths) ?? Duration.zero;
    // While it glides the row is laid out at the larger of its old and new heights and clipped to the height shown,
    // so a header's controls never squeeze.
    Widget glideRow(LayerDoc l, Widget Function(double h) build) {
      final target = rowH(l);
      return TweenAnimationBuilder<double>(
        tween: Tween(end: target), duration: rowGlide, curve: EditMotion.curve, onEnd: _rowsSettled,
        builder: (context, h, _) {
          if ((h - target).abs() < 0.01) return build(target);
          final room = math.max(h, target);
          return SizedBox(height: math.max(0.0, h), child: ClipRect(child: OverflowBox(alignment: Alignment.topCenter,
            minHeight: room, maxHeight: room, child: build(room))));
        });
    }
    // A track's automation lanes open and close by growing and shrinking under it, header and lanes together
    // (owner, 2026-11-11); once they have, the rows below take their places as they are.
    final lanesD = pinned ? null : EditMotion.of(context, EditMotionKind.lengths);
    Widget lanesReveal(LayerDoc l, Widget? lanes) {
      final open = lanes != null;
      if (_lanesSeen[l.id] != null && _lanesSeen[l.id] != open && lanesD != null) {
        Timer(lanesD + const Duration(milliseconds: 20), _rowsSettled);
      }
      _lanesSeen[l.id] = open;
      return AnimatedSwitcher(duration: lanesD ?? Duration.zero,
        switchInCurve: EditMotion.curve, switchOutCurve: EditMotion.exitCurve,
        transitionBuilder: (child, a) => SizeTransition(sizeFactor: a, alignment: Alignment.topCenter,
            child: FadeTransition(opacity: a, child: child)),
        child: lanes ?? const SizedBox(width: double.infinity));
    }
    // The take lanes open and close the same way.
    Widget takesReveal(LayerDoc l, Widget? lanes) => AnimatedSwitcher(duration: lanesD ?? Duration.zero,
        switchInCurve: EditMotion.curve, switchOutCurve: EditMotion.exitCurve,
        transitionBuilder: (child, a) => SizeTransition(sizeFactor: a, alignment: Alignment.topCenter,
            child: FadeTransition(opacity: a, child: child)),
        child: lanes ?? const SizedBox(width: double.infinity));
    // A thin row keeps its automation lanes closed.
    bool lanesOpen(LayerDoc l) => !pinned && l.showLanes && canHaveLanes(l) && _rowCollapse(l) != TrackCollapse.thin;
    // A thin row keeps its take lanes closed too (#209, comping).
    bool takesOpen(LayerDoc l) => !pinned && takeLanesHeight(l) > 0 && _rowCollapse(l) != TrackCollapse.thin;
    final rows = layers.fold<double>(0, (h, l) => h + rowH(l) + (pinned ? 0 : (lanesOpen(l) ? lanesHeight(s, l) : 0) +
        (takesOpen(l) ? takeLanesHeight(l) : 0) + l.spaceBelow) + gap);
    // Edit animations (owner, 2026-11-11): rows glide when tracks are added, deleted, reordered or nested, and a
    // track an edit added grows in. The first build, and the pinned track, just show what is there.
    final appearing = pinned || _knownTracks == null ? const <String>{}
        : {for (final l in layers) if (!_knownTracks!.contains(l.id)) l.id};
    if (!pinned) _knownTracks = {for (final l in layers) l.id};
    Widget row(String side, LayerDoc layer, List<Widget> children) => pinned
        ? Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: children)
        : TrackRowMotion(key: ValueKey('row-$side-${layer.id}'), id: '$side:${layer.id}', memory: _rowMemory,
            epoch: (trackHeight, _rowGen), appear: appearing.contains(layer.id),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
              children: children));
    // Two fingers scroll by their average, so a pinch zooms without dragging the view; the pointers are read raw.
    final tempoGlide = EditMotion.of(context, EditMotionKind.lengths) ?? Duration.zero;
    return TweenAnimationBuilder<double>(tween: Tween(end: tempoTarget), duration: tempoGlide, curve: EditMotion.curve,
      builder: (context, tempoH, _) {
    final ruler = pinned ? 20.0 : sectionH + rulerH + tempoH;
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(multitouchDragStrategy: MultitouchDragStrategy.averageBoundaryPointers),
      child: Listener(
      onPointerDown: (e) {
        _follow.hold();
        _glide.stop();
        _vGlide.stop();
        _touchDown(e, headW);
      },
      onPointerMove: (e) => _touchMove(e, headW),
      onPointerUp: (e) {
        _follow.release();
        _touchUp(e);
      },
      onPointerCancel: (e) {
        _follow.release();
        _touchUp(e);
      },
      onPointerSignal: (_) {
        _follow.touch();
        _glide.stop();
        _vGlide.stop();
      },
      onPointerPanZoomStart: (_) {
        _follow.hold();
        _glide.stop();
        _vGlide.stop();
      },
      onPointerPanZoomEnd: (_) => _follow.release(),
      child: LayoutBuilder(builder: (context, view) {
        // A pixel short of the view, so a few tracks still don't scroll (the lanes' column fills the view anyway).
        final zoneH = math.max(view.maxHeight - ruler - rows - 1, math.max(80.0, trackHeight * 1.5));
        // Repaint boundaries (#174): a scroll moves a layer already painted instead of repainting every track and
        // clip; only the grid and the ruler, which paint the visible span, repaint as the view moves.
        return SingleChildScrollView(key: drag?.vViewport, controller: drag?.vScroll, child: RepaintBoundary(child: Listener(
        onPointerSignal: (e) => _wheel(e, null),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Stack(children: [SizedBox(width: headW, child: Selected(
        select: () => (_headersRev, layers.length, zoneH),
        builder: (context) => Column(children: [
        SizedBox(height: ruler, child: Stack(children: [
          Positioned(left: 0, right: 0, top: 0, height: pinned ? ruler : sectionH + rulerH, child: Padding(
            padding: EdgeInsets.only(left: 10, top: pinned ? 4 : 8),
            child: Align(alignment: Alignment.centerLeft,
              child: Text(pinned ? 'FOCUS · swipe ‹ ›' : 'TRACKS',
                style: const TextStyle(color: Neon.dim, fontSize: 10, letterSpacing: 1.3))))),
          // The tempo lane's name, fading with it.
          if (tempoH > 0) Positioned(left: 0, right: 0, bottom: 0, height: tempoH, child: Opacity(
            opacity: (tempoH / tempoLaneHeight(_phone)).clamp(0.0, 1.0), child: TempoLaneHeader(state: s))),
        ])),
        for (final layer in layers) row('h', layer, [
          // A header builds again only when what it shows can have changed (#235): the project (any edit moves
          // [AppState.docGen]), its selection or focus, its place and size, or a recording starting or stopping; a
          // selection elsewhere or a transport change leaves it as built.
          glideRow(layer, (h) => Selected(select: () => (s.docGen, _settingsGen, p, layer, s.selectedLayerId == layer.id,
              layer.id == focusId, h, pinned ? TrackCollapse.normal : _rowCollapse(layer), p.layers.indexOf(layer),
              s.folderDepth(layer), headW, _phone, pinned, drag, AudioRecorder.current),
            builder: (context) => _TimelineHeader(key: drag?.headerKey(layer.id), state: s, layer: layer,
            index: p.layers.indexOf(layer),
            taps: _headerTaps,
            drag: drag, onTrackDrag: drag == null ? null : (phase, at) => _trackDrag(layer, phase, at),
            depth: pinned ? 0 : s.folderDepth(layer), trackHeight: h,
            collapse: pinned ? TrackCollapse.normal : _rowCollapse(layer),
            // A narrow header stands its meter up; a phone's narrowest one drops a compact row's M and S until the
            // track is selected (owner, 2026-11-11).
            uprightMeter: headW < uprightMeterWidth,
            hideMuteSolo: _phone && headW <= Settings.minHeaderWidth + 0.5,
            pinned: pinned,
            focused: layer.id == focusId,
            // The pinned track: a tap goes back to all tracks, a sideways swipe to the next or previous one.
            onTap: pinned ? () => _focus(null) : () => callbacks.onTap(layer),
            onSwipe: pinned ? _step : null,
            onFx: () => callbacks.onFx(layer),
            onMenu: (at) => callbacks.onMenu(layer, at),
            onResize: pinned ? null : (dy) => _rowResize(layer, dy),
            onResizeEnd: _rowResizeEnd))),
          // The track's take lanes (#209, comping), then its automation lanes (REAPER's envelope lanes, UG 18.16).
          if (!pinned) takesReveal(layer, takesOpen(layer) ? TakeLaneHeaders(key: ValueKey('take-headers-${layer.id}'),
              state: s, layer: layer, indent: folderIndent(s.folderDepth(layer))) : null),
          if (!pinned) lanesReveal(layer, lanesOpen(layer) ? TrackLaneHeaders(key: ValueKey('lane-headers-${layer.id}'),
              state: s, layer: layer, indent: folderIndent(s.folderDepth(layer))) : null),
          if (layer.spaceBelow > 0 && !pinned) _SpacerHeader(state: s, layer: layer),
          SizedBox(height: gap),
        ]),
        if (drag != null) NewTrackZone(key: drag.newTrackHeader, state: s, drag: drag, height: zoneH, header: true),
      ]))),
        // The headers' right edge: drag it to make the headers narrower or wider (saved).
        Positioned(right: 0, top: 0, bottom: 0, width: 10, child: _ResizeGrip(
          key: const ValueKey('header-width-grip'), axis: Axis.horizontal, label: 'Resize track headers',
          onDrag: (dx) => setState(() => _dragHeaderW = (_headerWidth + dx)
              .clamp(Settings.minHeaderWidth, Settings.maxHeaderWidth).toDouble()),
          onEnd: _saveHeaderSize)),
      ]),
      Expanded(child: RepaintBoundary(child: SingleChildScrollView(key: drag?.hViewport, controller: _hScroll, scrollDirection: Axis.horizontal,
        child: Listener(
          onPointerSignal: (e) => _wheel(e, _hScroll.hasClients ? e.localPosition.dx - _hScroll.positions.last.pixels : null),
          // The lanes as wide as the timeline at this zoom; everything in them that depends on it lays out at it.
          child: RepaintBoundary(child: ValueListenableBuilder<double>(valueListenable: _stepWN,
            builder: (context, w, child) => SizedBox(key: pinned ? null : _lanesBox, width: widthAt(w), child: child),
            child: Stack(children: [
          // One grid behind every track, through the gaps and spacers and down to the bottom of the view
          // below the last track (owner: like Reaper).
          Positioned(left: 0, right: 0, top: ruler, bottom: 0, child: IgnorePointer(child: RepaintBoundary(child: zoomed(
            (stepW) => CustomPaint(painter: _ArrangementGrid(stepW, p.bars, _hScroll)))))),
          // The loop range's edges, down through the lanes while it is on; they fade out when it goes.
          Positioned(left: 0, right: 0, top: ruler, bottom: 0, child: IgnorePointer(child: zoomed((stepW) => FadeHold<(int, int)>(
            value: p.loopsRange ? (p.loopStartSteps, p.loopEndSteps) : null,
            builder: (context, r) => Stack(children: [
              for (final at in [r.$1, r.$2])
                Positioned(left: at * stepW - 0.5, top: 0, bottom: 0, width: 1,
                  child: ColoredBox(color: Neon.blue.withValues(alpha: 0.45))),
            ]))))),
          // Where the song ends and playback loops back to the start.
          zoomed((stepW) => Positioned(left: end * stepW - 1, top: 0, bottom: 0, width: 2, child: IgnorePointer(
            child: Tooltip(message: 'Song end: playback loops back to the start',
              child: Container(color: Neon.pink.withValues(alpha: 0.7)))))),
          ConstrainedBox(constraints: BoxConstraints(minHeight: pinned ? 0 : view.maxHeight), child: RepaintBoundary(child: Column(children: [
            RepaintBoundary(child: pinned
                ? zoomed((stepW) => SizedBox(height: ruler, width: widthAt(stepW),
                    child: CustomPaint(painter: _BarRuler(stepW, p.bars, _hScroll))))
                : Column(mainAxisSize: MainAxisSize.min, children: [
                    // Their own layers: the ruler repaints as the view scrolls, the section bar and lane don't.
                    RepaintBoundary(child: zoomed((stepW) => ArrangeSectionBar(state: s, stepW: stepW,
                        width: widthAt(stepW), height: sectionH))),
                    zoomed((stepW) => ArrangeRuler(state: s, stepW: stepW, width: widthAt(stepW), height: rulerH,
                        scroll: _hScroll)),
                    // It grows in under the ruler and shrinks away, laid out whole and clipped meanwhile.
                    if (tempoH > 0) ClipRect(child: zoomed((stepW) => SizedBox(height: tempoH, width: widthAt(stepW),
                      child: OverflowBox(
                      alignment: Alignment.topCenter, minHeight: tempoLaneHeight(_phone),
                      maxHeight: tempoLaneHeight(_phone),
                      child: RepaintBoundary(child: TempoLane(state: s, stepW: stepW, width: widthAt(stepW),
                          height: tempoLaneHeight(_phone))))))),
                  ])),
            for (final layer in layers) row('l', layer, [
              glideRow(layer, (h) => zoomed((stepW) => _TimelineLane(key: drag?.laneKey(layer.id), state: s,
                layer: layer, width: widthAt(stepW), stepW: stepW, zoom: _stepWN, gen: gen,
                look: (s.docGen, _settingsGen, p), trackHeight: h,
                selectedIds: s.selectedClipIds, callbacks: callbacks, drag: drag,
                thin: !pinned && _rowCollapse(layer) == TrackCollapse.thin))),
              if (!pinned) takesReveal(layer, takesOpen(layer) ? zoomed((stepW) =>
                  TakeLaneRows(state: s, layer: layer, stepW: stepW, width: widthAt(stepW))) : null),
              if (!pinned) lanesReveal(layer, lanesOpen(layer) ? zoomed((stepW) =>
                  TrackLaneRows(state: s, layer: layer, stepW: stepW, width: widthAt(stepW))) : null),
              // A spacer and the gap leave the timeline empty too, so lanes stay level with their headers.
              if (layer.spaceBelow > 0 && !pinned) SizedBox(height: layer.spaceBelow),
              SizedBox(height: gap),
            ]),
            if (drag != null) zoomed((stepW) => SizedBox(width: widthAt(stepW),
              child: NewTrackZone(key: drag.newTrackLane, state: s, drag: drag, height: zoneH, stepW: stepW))),
          ]))),
          // One hint while no track holds a clip (owner, 2026-11-11), centred in the view below the ruler; it fades
          // out with the first clip.
          if (!pinned) Positioned(left: 10, top: ruler + (view.maxHeight - ruler) / 2 - 8, child: IgnorePointer(
            child: AnimatedSwitcher(
              duration: EditMotion.of(context, EditMotionKind.panels) ?? Duration.zero,
              switchInCurve: EditMotion.curve, switchOutCurve: EditMotion.exitCurve,
              child: s.project.layers.any((l) => l.clips.isNotEmpty || l.audioClips.isNotEmpty)
                  ? const SizedBox.shrink()
                  : SizedBox(key: const ValueKey('arrange-hint'), height: 16, child: Text(
                      s.project.layers.every((l) => l.isFolder || l.isAudio)
                          ? 'Drop audio here, or arm the track and record'
                          : 'Double-tap for a clip, or drop a pattern here',
                      style: const TextStyle(color: Neon.dim, fontSize: 10)))))),
          // A live island (widgets.dart): the line moves on every frame while playing (live_playhead.dart), and
          // without it the timeline around it would lay out and repaint with it. Smooth follow scrolls in the same
          // frame, so the line holds still a third in.
          Positioned.fill(child: IgnorePointer(child: LiveIsland(child: zoomed((stepW) => PlayheadFrames(
            state: s,
            onFrame: () {
              if (s.settings.followSmooth) _followPlayhead();
            },
            builder: (context) {
              // Stopped, a dimmer line shows where play starts and Split cuts (REAPER's edit cursor).
              final playing = s.meters.playing && s.meters.loopLength > 0;
              return CustomPaint(painter: _PlayheadPainter(stepW,
                s.smoothPlayheadStep, stopped: !playing));
            },
          ))))),
          // A dragged or trimmed clip's guides, through the ruler and every track (owner, 2026-11-12).
          Positioned.fill(child: zoomed((stepW) =>
              ClipGuides(guides: _guides, stepW: stepW, rulerH: ruler, beatsPerBar: p.beatsPerBar))),
          if (!pinned) Positioned.fill(child: IgnorePointer(child: ValueListenableBuilder<Rect?>(
            valueListenable: _marquee,
            builder: (context, box, _) {
              final me = _lanesBox.currentContext?.findRenderObject();
              if (box == null || me is! RenderBox || !me.attached) return const SizedBox.shrink();
              final local = Rect.fromPoints(me.globalToLocal(box.topLeft), me.globalToLocal(box.bottomRight));
              return CustomPaint(painter: _MarqueePainter(local));
            }))),
        ]))))))),
    ]))));
      })));
      });
  }

  Widget _arrangement(BuildContext context, _TrackCallbacks callbacks) {
    final s = widget.state;
    final tracks = s.project.layers.isEmpty
        ? _EmptyArrangement(onAdd: () { Haptics.tap(); s.addLayer(); }, onBrowse: () => setState(() => _browser = true))
        : _timeline(context, s.visibleLayers, callbacks);
    // The mixer card slides up over the tracks and back down (owner, 2026-11-11).
    return LayoutBuilder(builder: (context, box) => Stack(children: [
      Positioned.fill(child: tracks),
      Positioned(left: 6, right: 6, bottom: 6, height: math.min(box.maxHeight - 12, math.max(320.0, box.maxHeight * 0.86)),
        child: Presence(from: const Offset(0, 0.15), child: !mixerCard ? null
            : MixerCard(state: s, onClose: () => setState(() => mixerCard = false)))),
    ]));
  }
}
