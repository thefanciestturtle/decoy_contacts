// Which live region texts TalkBack reads out, worked out from the app's
// semantics updates. Shared by the widget tests and the on-device tests.

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records, from its creation until [dispose], the texts of live regions
/// that TalkBack would read out ([texts]) or miss ([missed]), in order.
///
/// A live region's text is read out when it appears or changes, but not
/// when that happens in the same update as a change of route, e.g. a
/// dialog going away. (Measured on the emulator, API 36, TalkBack 16: a
/// result shown while a dialog still covers the page comes back with the
/// page, in the update in which the dialog goes, and is never read out;
/// one shown an update later is.)
///
/// Call [dispose] at the end of the test: flutter_test checks for open
/// semantics handles before its tear-downs run. (A tear-down disposes of
/// it too, in case the test fails first.)
class LiveRegionAnnouncements {
  LiveRegionAnnouncements(WidgetTester tester)
      : _handle = tester.ensureSemantics(),
        _owner = tester.binding.renderViews.first.owner!.semanticsOwner! {
    // What TalkBack knows already, if anything (else the first update
    // brings it all).
    _read();
    _owner.addListener(_updated);
    addTearDown(dispose);
  }

  final SemanticsHandle _handle;
  final SemanticsOwner _owner;

  /// The texts read out so far.
  final List<String> texts = [];

  /// The texts that appeared or changed, but weren't read out.
  final List<String> missed = [];

  /// The last text of each live region, by node ID; also of one hidden
  /// since by a route (e.g. a menu), as long as it may come back with it.
  final Map<int, String> _previous = {};

  /// The IDs of the nodes that scope a route, in the last update.
  List<int> _previousRoutes = [];

  /// Reads the tree as it is now (its live regions' texts, and its routes)
  /// and keeps it as the last update's.
  ({Map<int, String> live, List<int> routes}) _read() {
    final live = <int, String>{};
    final routes = <int>[];
    bool visit(SemanticsNode node) {
      final flags = node.flagsCollection;
      if (flags.isLiveRegion) live[node.id] = node.label;
      if (flags.scopesRoute) routes.add(node.id);
      node.visitChildren(visit);
      return true;
    }

    final root = _owner.rootSemanticsNode;
    if (root != null) visit(root);
    _previous.addAll(live);
    _previousRoutes = routes;
    return (live: live, routes: routes);
  }

  void _updated() {
    final before = Map<int, String>.of(_previous);
    final routesBefore = _previousRoutes;
    final (:live, :routes) = _read();
    final bRouteChanged = !listEquals(routes, routesBefore);
    live.forEach((id, text) {
      if (text.isEmpty || text == before[id]) return;
      (bRouteChanged ? missed : texts).add(text);
    });
    // Gone without a change of route: emptied, not hidden.
    if (!bRouteChanged) _previous.removeWhere((id, _) => !live.containsKey(id));
  }

  bool _bDisposed = false;

  void dispose() {
    if (_bDisposed) return;
    _bDisposed = true;
    _owner.removeListener(_updated);
    _handle.dispose();
  }
}
