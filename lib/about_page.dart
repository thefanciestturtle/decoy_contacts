// The About screen, opened from the home page's menu: what the app does and
// what it stores, its privacy policy, its version, and where its source
// code and licences are.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_log.dart';
import 'app_theme.dart';

/// The app's version, as in pubspec.yaml (a test checks they match).
const String kAppVersion = '1.8.0';

/// Where the source code is, and how the link to it reads.
final Uri kSourceUrl =
    Uri.parse('https://github.com/thefanciestturtle/fake_contacts');
const String kSourceLabel = 'github.com/thefanciestturtle/fake_contacts';

/// The privacy policy, word for word as under "Privacy Policy" in
/// README.md, which is where it is kept (a test checks they match).
const String kPrivacyPolicy =
    "This application doesn't collect, store or transmit your identity or "
    "personal information in any way. It contains no advertising and no "
    "trackers. It has no internet access.";

/// The app's own licence, as in LICENSE.md (a test checks they match),
/// for Flutter's licence page.
const String kAppLicense = 'The MIT License (MIT)\n'
    '\n'
    'Copyright (c) 2021 Bill Dietrich\n'
    '\n'
    'Permission is hereby granted, free of charge, to any person obtaining a '
    'copy of this software and associated documentation files (the '
    '"Software"), to deal in the Software without restriction, including '
    'without limitation the rights to use, copy, modify, merge, publish, '
    'distribute, sublicense, and/or sell copies of the Software, and to '
    'permit persons to whom the Software is furnished to do so, subject to '
    'the following conditions:\n'
    '\n'
    'The above copyright notice and this permission notice shall be '
    'included in all copies or substantial portions of the Software.\n'
    '\n'
    'THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS '
    'OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF '
    'MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. '
    'IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY '
    'CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, '
    'TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE '
    'SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.';

/// The name the app's licence is listed under on the licence page.
const String kLicensePackage = 'fake_contacts';

bool _bLicenseRegistered = false;

/// Adds the app's own licence ([kAppLicense]) to the ones Flutter's
/// licence page lists (the packages the app uses); once.
void registerAppLicense() {
  if (_bLicenseRegistered) return;
  _bLicenseRegistered = true;
  LicenseRegistry.addLicense(() => Stream.value(
      const LicenseEntryWithLineBreaks([kLicensePackage], kAppLicense)));
}

/// The text under each heading, a paragraph per string.
const List<(String, List<String>)> kAboutSections = [
  ('What it does', [
    'Some apps and companies copy the contacts on your phone, to use or '
        'sell them. This app adds fake contacts among your real ones, so '
        'what they copy is worth less. This is called data poisoning.',
    "The fake contacts don't get in the way of your real ones. By default "
        'their names start with Z, so they sort to the end.',
  ]),
  ('Create and Delete', [
    'Create adds a fake contact for each first name with each last name. '
        'In the templates, each n becomes a digit, and FIRST and LAST '
        'become the names.',
    'Delete only removes fake contacts this app created, and only if they '
        'are still as it made them. Your real contacts are never touched.',
  ]),
  ('What it stores', [
    'Your names and templates, and a list of the fake contacts it created, '
        "so Delete can find them. They stay in the app's own storage on "
        'this phone.',
  ]),
  ('New phone or backup', [
    "That list isn't backed up or moved to a new phone. After a move to a "
        "new phone, clearing the app's data, uninstalling it or restoring "
        "your contacts from a backup, Delete can't find the fake contacts "
        'made before. Delete them in your Contacts app.',
  ]),
  ('Privacy policy', [kPrivacyPolicy]),
  ('Source code', ['Free software under the MIT license.']),
];

/// Shown under the link if no app could open it.
const String kLinkFailedText = "Couldn't open the link in a browser.";

/// How far an arrow key scrolls the text (as Flutter's own scrolling by
/// keyboard: a line, about).
const double kArrowScrollStep = 50;

/// Opens [url] in the browser (another app: this one has no internet
/// access). False if no app could open it.
Future<bool> openInBrowser(Uri url) =>
    launchUrl(url, mode: LaunchMode.externalApplication);

class AboutPage extends StatefulWidget {
  const AboutPage({super.key, this.openLink = openInBrowser});

  /// Opens a link; tests pass one that only records it.
  final Future<bool> Function(Uri url) openLink;

  static const Key keyText = Key('AboutText');
  static const Key keySourceLink = Key('SourceLink');
  static const Key keyLinkFailed = Key('LinkFailed');
  static const Key keyLicenses = Key('Licenses');

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  final ScrollController _scroll = ScrollController();

  /// The text as a whole takes the keyboard focus, so it can be scrolled
  /// with the arrow and page keys: a keyboard or D-pad user couldn't read
  /// it otherwise, since only the link and the button below it could have
  /// the focus.
  final FocusNode _textFocus = FocusNode(debugLabel: 'About text');

  bool _bLinkFailed = false;

  /// Set while the link is being opened: a second tap meanwhile does
  /// nothing.
  bool _bOpening = false;

  /// Where a scroll by key is heading, while it runs: the next key press
  /// goes on from there (a key held down repeats faster than the scroll).
  double? _scrollTarget;

  @override
  void dispose() {
    _scroll.dispose();
    _textFocus.dispose();
    super.dispose();
  }

  /// Up and Down scroll the text by about a line, Page Up and Page Down
  /// by most of a screen, while the text has the focus. Up at the top or
  /// Down at the end moves the focus on, as from any other item.
  KeyEventResult _scrollByKey(FocusNode node, KeyEvent event) {
    if (!node.hasPrimaryFocus || event is KeyUpEvent || !_scroll.hasClients) {
      return KeyEventResult.ignored;
    }
    final position = _scroll.position;
    final key = event.logicalKey;
    final double step;
    if (key == LogicalKeyboardKey.arrowDown) {
      step = kArrowScrollStep;
    } else if (key == LogicalKeyboardKey.arrowUp) {
      step = -kArrowScrollStep;
    } else if (key == LogicalKeyboardKey.pageDown) {
      step = position.viewportDimension * 0.8;
    } else if (key == LogicalKeyboardKey.pageUp) {
      step = -position.viewportDimension * 0.8;
    } else {
      return KeyEventResult.ignored;
    }
    final double from = _scrollTarget ?? position.pixels;
    final double target = (from + step)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if (target == from) {
      // Not while it still scrolls there: a key held down waits for the
      // end to be in view.
      if (_scrollTarget != null) return KeyEventResult.handled;
      if (key == LogicalKeyboardKey.arrowDown) node.nextFocus();
      if (key == LogicalKeyboardKey.arrowUp) node.previousFocus();
      return KeyEventResult.handled;
    }
    _scrollTarget = target;
    // (Also done if the scroll is cut short, say by a touch.)
    unawaited(position
        .animateTo(target,
            duration: const Duration(milliseconds: 100), curve: Curves.easeInOut)
        .whenComplete(() {
      if (_scrollTarget == target) _scrollTarget = null;
    }));
    return KeyEventResult.handled;
  }

  Future<void> _openSource() async {
    if (_bOpening) return;
    _bOpening = true;
    setState(() => _bLinkFailed = false);
    bool bOpened;
    try {
      bOpened = await widget.openLink(kSourceUrl);
    } catch (e, st) {
      logError('AboutPage, opening the link', e, st);
      bOpened = false;
    } finally {
      _bOpening = false;
    }
    if (!mounted) return;
    setState(() => _bLinkFailed = !bOpened);
  }

  void _showLicenses() {
    registerAppLicense();
    showLicensePage(
      context: context,
      applicationName: 'Fake Contacts',
      applicationVersion: kAppVersion,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final body = theme.textTheme.bodyLarge;
    return Scaffold(
      appBar: AppBar(
        // (Centred, as the app bar centres a back button of its own: at
        // its size, with room for the ring.)
        leading: const FocusRing(child: Center(child: BackButton())),
        title: const Text('About'),
      ),
      body: SafeArea(
        child: FocusRing(
          focusNode: _textFocus,
          inward: true,
          shape: const RoundedRectangleBorder(),
          child: Focus(
            key: AboutPage.keyText,
            focusNode: _textFocus,
            // TalkBack goes through the text by itself.
            includeSemantics: false,
            onKeyEvent: _scrollByKey,
            child: SingleChildScrollView(
              controller: _scroll,
              padding: const EdgeInsets.all(16),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 600),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      // (Android takes a heading from its level: TalkBack
                      // can then go from heading to heading.)
                      Semantics(
                        header: true,
                        headingLevel: 1,
                        child: Text('Fake Contacts',
                            style: theme.textTheme.headlineSmall),
                      ),
                      const SizedBox(height: 4),
                      Text('Version $kAppVersion',
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: colors.onSurfaceVariant)),
                      for (final (heading, paragraphs) in kAboutSections) ...[
                        const SizedBox(height: 24),
                        Semantics(
                          header: true,
                          headingLevel: 2,
                          child: Text(heading,
                              style: theme.textTheme.titleMedium),
                        ),
                        for (final paragraph in paragraphs) ...[
                          const SizedBox(height: 8),
                          Text(paragraph, style: body),
                        ],
                      ],
                      const SizedBox(height: 8),
                      _buildSourceLink(context),
                      // Read out if it appears.
                      Semantics(
                        container: true,
                        liveRegion: true,
                        child: _bLinkFailed
                            ? Text(kLinkFailedText,
                                key: AboutPage.keyLinkFailed,
                                style: body?.copyWith(color: colors.error))
                            : const SizedBox.shrink(),
                      ),
                      const SizedBox(height: 16),
                      FocusRing(
                        child: OutlinedButton(
                          key: AboutPage.keyLicenses,
                          onPressed: _showLicenses,
                          child: const Text('Licenses'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The link to the source code: underlined text, at least as tall as a
  /// button to tap. Marked as a link, without its address: given one,
  /// Flutter passes it to Android inside the text, and TalkBack then reads
  /// out only the text, not that it can be opened (checked on API 36).
  /// Without it, TalkBack calls it a button, and says to double-tap it.
  Widget _buildSourceLink(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;
    const corners = BorderRadius.all(Radius.circular(4));
    return Semantics(
      link: true,
      child: FocusRing(
        shape: const RoundedRectangleBorder(borderRadius: corners),
        child: InkWell(
          key: AboutPage.keySourceLink,
          onTap: _openSource,
          borderRadius: corners,
          child: ConstrainedBox(
            constraints:
                const BoxConstraints(minHeight: kMinInteractiveDimension),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              widthFactor: 1,
              child: Text(
                kSourceLabel,
                style: theme.textTheme.bodyLarge?.copyWith(
                    color: color,
                    decoration: TextDecoration.underline,
                    decorationColor: color),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
