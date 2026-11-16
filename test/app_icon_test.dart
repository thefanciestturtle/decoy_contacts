// The app's icon. Android 8 and newer draw the adaptive icon
// (mipmap-anydpi-v26/ic_launcher.xml): a background colour, a foreground
// vector, and a monochrome vector for themed icons (Android 13 and newer).
// Android 7 and the app stores use PNGs, which tool/make_icon_pngs.py draws
// from the background and the foreground. These tests keep the layers
// inside the part of the icon every launcher shows, the themed icon right,
// and the PNGs in step with the layers: they draw the layers with Flutter's
// renderer (not the tool's) and compare.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'png_file.dart';

const res = 'android/app/src/main/res';
const adaptiveIconPath = '$res/mipmap-anydpi-v26/ic_launcher.xml';
const backgroundPath = '$res/values/ic_launcher_background.xml';
const foregroundPath = '$res/drawable/ic_launcher_foreground.xml';
const monochromePath = '$res/drawable/ic_launcher_monochrome.xml';

/// The PNGs and their widths in pixels: the launcher icon for Android 7
/// (48 dp) at each density, and the store icon.
const pngWidths = {
  '$res/mipmap-mdpi/ic_launcher.png': 48,
  '$res/mipmap-hdpi/ic_launcher.png': 72,
  '$res/mipmap-xhdpi/ic_launcher.png': 96,
  '$res/mipmap-xxhdpi/ic_launcher.png': 144,
  '$res/mipmap-xxxhdpi/ic_launcher.png': 192,
  'fastlane/metadata/android/en-US/images/icon.png': 512,
};

/// An adaptive icon's layers are 108 dp square. A launcher shows at most
/// the middle 72 dp, cut to its shape, and always the circle of 66 dp in
/// the middle: the safe zone.
const layerSize = 108.0;
const centre = ui.Offset(54, 54);
const visibleRadius = 36.0;
const safeRadius = 33.0;

/// The PNGs are the visible circle, 44/48 of their width (Material's
/// keyline for a round icon).
const keyline = 44 / 48;

/// An XML element: its tag, its attributes, and the elements in it.
class XmlElement {
  XmlElement(this.tag, this.attributes);

  final String tag;
  final Map<String, String> attributes;
  final children = <XmlElement>[];

  /// The value of the attribute android:[name].
  String? operator [](String name) => attributes['android:$name'];
}

/// The root element of the XML file at [path]. Reads only the plain XML of
/// these resource files: comments are dropped, and text between the tags
/// is not kept.
XmlElement readXml(String path) {
  final text = File(path)
      .readAsStringSync()
      .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '')
      .replaceFirst(RegExp(r'^<\?xml[^>]*\?>'), '');
  final tag = RegExp(r'<(/?)([\w:-]+)((?:\s+[\w:]+="[^"]*")*)\s*(/?)>');
  expect(
    text.replaceAll(tag, ''),
    isNot(contains(RegExp('[<>]'))),
    reason: '$path: every tag is one this test can read',
  );
  final document = XmlElement('', {});
  final open = [document];
  for (final match in tag.allMatches(text)) {
    final name = match[2]!;
    if (match[1] == '/') {
      expect(open.last.tag, name, reason: '$path: </$name> closes <$name>');
      open.removeLast();
      continue;
    }
    final element = XmlElement(name, {
      for (final attribute in RegExp(
        r'([\w:]+)="([^"]*)"',
      ).allMatches(match[3]!))
        attribute[1]!: attribute[2]!,
    });
    open.last.children.add(element);
    if (match[4] != '/') open.add(element);
  }
  expect(open, [document], reason: '$path: every tag is closed');
  expect(document.children, hasLength(1), reason: '$path: one root');
  return document.children.single;
}

/// The colour #RRGGBB or #AARRGGBB.
ui.Color parseColour(String text, String where) {
  final match = RegExp(r'^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$').firstMatch(text);
  expect(match, isNotNull, reason: '$where: colour $text');
  final digits = match![1]!;
  return ui.Color(
    int.parse(digits.length == 6 ? 'FF$digits' : digits, radix: 16),
  );
}

/// The icon's background colour.
ui.Color backgroundColour() {
  final colours = RegExp(
    r'<color name="ic_launcher_background">([^<]*)</color>',
  ).allMatches(File(backgroundPath).readAsStringSync());
  expect(colours, hasLength(1), reason: backgroundPath);
  return parseColour(colours.single[1]!.trim(), backgroundPath);
}

/// One closed part of a path: where it starts, and its segments, each the
/// points it goes through after the point before: the end for a line, two
/// control points and the end for a cubic. It closes with a line back to
/// the start.
typedef Subpath = ({ui.Offset start, List<List<ui.Offset>> segments});

const number = r'[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?';

/// The subpaths of path data, which may only use the commands
/// tool/make_icon_pngs.py draws: absolute M, L, C and Z, each subpath
/// closed.
List<Subpath> parsePath(String data, String where) {
  expect(
    data.replaceAll(RegExp('[A-Za-z]|$number|[\\s,]'), ''),
    isEmpty,
    reason: '$where: path data of commands and numbers',
  );
  final tokens = [
    for (final match in RegExp('[A-Za-z]|$number').allMatches(data)) match[0]!,
  ];
  final subpaths = <Subpath>[];
  ui.Offset? start;
  var segments = <List<ui.Offset>>[];
  var at = 0;
  ui.Offset point() {
    expect(at + 2, lessThanOrEqualTo(tokens.length), reason: where);
    final offset = ui.Offset(
      double.parse(tokens[at]),
      double.parse(tokens[at + 1]),
    );
    at += 2;
    return offset;
  }

  while (at < tokens.length) {
    final command = tokens[at++];
    if (command != 'M') {
      expect(start, isNotNull, reason: '$where: a subpath starts with M');
    }
    switch (command) {
      case 'M':
        expect(start, isNull, reason: '$where: each subpath ends with Z');
        start = point();
        segments = [];
      case 'L':
        segments.add([point()]);
      case 'C':
        segments.add([point(), point(), point()]);
      case 'Z':
        subpaths.add((start: start!, segments: segments));
        start = null;
      default:
        fail(
          '$where: path command $command (only absolute M, L, C and Z, '
          'which tool/make_icon_pngs.py draws)',
        );
    }
    if (at < tokens.length) {
      expect(
        tokens[at],
        matches(RegExp(r'^[A-Za-z]$')),
        reason: '$where: a command for each segment',
      );
    }
  }
  expect(start, isNull, reason: '$where: the last subpath ends with Z');
  return subpaths;
}

/// [subpaths] as a path to draw.
ui.Path toPath(List<Subpath> subpaths, {bool evenOdd = false}) {
  final path = ui.Path()
    ..fillType = evenOdd ? ui.PathFillType.evenOdd : ui.PathFillType.nonZero;
  for (final subpath in subpaths) {
    path.moveTo(subpath.start.dx, subpath.start.dy);
    for (final points in subpath.segments) {
      if (points.length == 1) {
        path.lineTo(points[0].dx, points[0].dy);
      } else {
        path.cubicTo(
          points[0].dx,
          points[0].dy,
          points[1].dx,
          points[1].dy,
          points[2].dx,
          points[2].dy,
        );
      }
    }
    path.close();
  }
  return path;
}

/// The segments of [subpath], each as the points from where it starts to
/// where it ends, with the closing line if it has a length.
List<List<ui.Offset>> edges(Subpath subpath) {
  final result = <List<ui.Offset>>[];
  var from = subpath.start;
  for (final points in subpath.segments) {
    result.add([from, ...points]);
    from = points.last;
  }
  if (from != subpath.start) result.add([from, subpath.start]);
  return result;
}

/// [subpath] as text that is the same for the same shape drawn the same
/// way round, whichever point it starts from.
String shapeKey(Subpath subpath) => (edges(
  subpath,
).map((points) => points.join(' ')).toList()..sort()).join(' / ');

/// The elements of a vector drawable, the attributes each may have, and so
/// what tool/make_icon_pngs.py can draw.
const vectorAttributes = {
  'vector': {
    'xmlns:android',
    'android:width',
    'android:height',
    'android:viewportWidth',
    'android:viewportHeight',
  },
  'group': {'android:name'},
  'clip-path': {'android:name', 'android:pathData'},
  'path': {
    'android:name',
    'android:pathData',
    'android:fillColor',
    'android:fillAlpha',
    'android:fillType',
  },
};

/// Every element in [element] and below it, [element] first.
Iterable<XmlElement> allElements(XmlElement element) sync* {
  yield element;
  for (final child in element.children) {
    yield* allElements(child);
  }
}

/// The subpaths of the `<path>` elements of the vector drawable at [path]
/// (what it draws, not what it clips with).
List<Subpath> drawnSubpaths(String path) => [
  for (final element in allElements(readXml(path)))
    if (element.tag == 'path') ...parsePath(element['pathData']!, path),
];

/// Draws the children of [element], a vector drawable or a group in it, as
/// Android does: a clip path clips what comes after it in its group.
void drawChildren(ui.Canvas canvas, XmlElement element, String where) {
  for (final child in element.children) {
    switch (child.tag) {
      case 'group':
        canvas.save();
        drawChildren(canvas, child, where);
        canvas.restore();
      case 'clip-path':
        // Android's clip paths fill by the nonzero rule.
        canvas.clipPath(toPath(parsePath(child['pathData']!, where)));
      case 'path':
        final colour = parseColour(child['fillColor']!, where);
        final alpha = double.parse(child['fillAlpha'] ?? '1');
        canvas.drawPath(
          toPath(
            parsePath(child['pathData']!, where),
            evenOdd: child['fillType'] == 'evenOdd',
          ),
          ui.Paint()..color = colour.withValues(alpha: colour.a * alpha),
        );
      default:
        fail('$where: <${child.tag}>');
    }
  }
}

/// Draws with [draw], in layer coordinates, onto [width] x [width] pixels
/// that show the middle [dpWidth] dp of the layers, and returns the pixels
/// (RGBA, alpha premultiplied).
Future<Uint8List> render(
  int width,
  double dpWidth,
  void Function(ui.Canvas canvas) draw,
) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final scale = width / dpWidth;
  canvas
    ..scale(scale)
    ..translate(dpWidth / 2 - centre.dx, dpWidth / 2 - centre.dy);
  draw(canvas);
  final image = await recorder.endRecording().toImage(width, width);
  final bytes = await image.toByteData();
  image.dispose();
  return bytes!.buffer.asUint8List();
}

/// The round icon the PNGs show, drawn by Flutter: the background and the
/// foreground, cut to the visible circle, which is 44/48 of [width].
Future<Uint8List> renderRoundIcon(int width) => render(
  width,
  2 * visibleRadius / keyline,
  (canvas) {
    canvas
      ..clipPath(
        ui.Path()
          ..addOval(ui.Rect.fromCircle(center: centre, radius: visibleRadius)),
      )
      ..drawPaint(ui.Paint()..color = backgroundColour());
    drawChildren(canvas, readXml(foregroundPath), foregroundPath);
  },
);

/// The pixels (RGBA, alpha premultiplied) of the PNG file at [path].
Future<Uint8List> decodePng(String path) async {
  final codec = await ui.instantiateImageCodec(File(path).readAsBytesSync());
  final frame = await codec.getNextFrame();
  final bytes = await frame.image.toByteData();
  frame.image.dispose();
  codec.dispose();
  return bytes!.buffer.asUint8List();
}

void main() {
  group('the adaptive icon', () {
    test('is the launcher icon, with a background, a foreground and a '
        'monochrome layer', () {
      expect(
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync(),
        contains('android:icon="@mipmap/ic_launcher"'),
      );
      final icon = readXml(adaptiveIconPath);
      expect(icon.tag, 'adaptive-icon');
      expect(
        {for (final layer in icon.children) layer.tag: layer['drawable']},
        {
          'background': '@color/ic_launcher_background',
          'foreground': '@drawable/ic_launcher_foreground',
          'monochrome': '@drawable/ic_launcher_monochrome',
        },
      );
      expect(icon.children, hasLength(3));
      backgroundColour();
      for (final path in [foregroundPath, monochromePath]) {
        expect(File(path).existsSync(), isTrue, reason: path);
      }
    });

    test('layers are 108 dp vectors with only what tool/make_icon_pngs.py '
        'draws', () {
      for (final path in [foregroundPath, monochromePath]) {
        final vector = readXml(path);
        expect(vector.tag, 'vector', reason: path);
        expect(vector['width'], '108dp', reason: path);
        expect(vector['height'], '108dp', reason: path);
        expect(vector['viewportWidth'], '108', reason: path);
        expect(vector['viewportHeight'], '108', reason: path);
        for (final element in allElements(vector)) {
          final where = '$path: <${element.tag}>';
          expect(vectorAttributes.keys, contains(element.tag), reason: where);
          expect(
            vectorAttributes[element.tag],
            containsAll(element.attributes.keys),
            reason: where,
          );
          if (element.tag == 'path') {
            parseColour(element['fillColor']!, where);
            final alpha = double.parse(element['fillAlpha'] ?? '1');
            expect(alpha, inInclusiveRange(0, 1), reason: where);
            expect(
              ['nonZero', 'evenOdd'],
              contains(element['fillType'] ?? 'nonZero'),
              reason: where,
            );
          }
          if (element.tag == 'path' || element.tag == 'clip-path') {
            parsePath(element['pathData']!, where);
          }
        }
      }
    });

    test('draws only inside the safe zone, which no launcher cuts', () {
      for (final path in [foregroundPath, monochromePath]) {
        // A cubic stays inside its control points, so it is enough that
        // they are all inside the circle.
        for (final subpath in drawnSubpaths(path)) {
          for (final point in edges(subpath).expand((points) => points)) {
            expect(
              (point - centre).distance,
              lessThanOrEqualTo(safeRadius),
              reason: '$path: $point',
            );
          }
        }
      }
    });

    test('the themed icon draws shapes of the foreground, in one colour', () {
      final foreground = drawnSubpaths(foregroundPath).map(shapeKey).toSet();
      final monochrome = drawnSubpaths(monochromePath).map(shapeKey).toSet();
      expect(monochrome, isNotEmpty);
      expect(foreground, containsAll(monochrome));
      // Android replaces the colour (it counts only the alpha), so a
      // second colour would be lost; fainter parts use fillAlpha.
      for (final element in allElements(readXml(monochromePath))) {
        if (element.tag == 'path') {
          expect(element['fillColor'], '#FFFFFFFF', reason: monochromePath);
        }
      }
    });

    test('the duck is whole where its parts meet, in both layers', () async {
      // Points in layer coordinates, and the colour of the foreground on
      // the background and the alpha of the themed icon there.
      const white = ui.Color(0xFFFFFFFF);
      final background = backgroundColour();
      final expected = {
        'where the head joins the body': ((67.5, 49.0), white, 1.0),
        'the head': ((70.0, 44.0), white, 1.0),
        'the body': ((66.0, 60.0), white, 1.0),
        'the tail': ((26.5, 51.5), white, 1.0),
        'the eye': ((66.4, 40.3), const ui.Color(0xFF10233C), 0.0),
        'the bill': ((79.0, 43.8), const ui.Color(0xFFF2A33A), 1.0),
        'the wing': ((46.0, 56.0), const ui.Color(0xFFD1E4FF), 1.0),
        'the water line': ((54.0, 73.0), const ui.Color(0xFFA5B8CC), 0.55),
        'between the duck and the water': ((54.0, 68.5), background, 0.0),
        'above the duck': ((54.0, 40.0), background, 0.0),
      };
      const pixelsPerDp = 4;
      const width = layerSize * pixelsPerDp;
      final colour = await render(width.round(), layerSize, (canvas) {
        canvas.drawPaint(ui.Paint()..color = background);
        drawChildren(canvas, readXml(foregroundPath), foregroundPath);
      });
      final monochrome = await render(
        width.round(),
        layerSize,
        (canvas) =>
            drawChildren(canvas, readXml(monochromePath), monochromePath),
      );
      for (final MapEntry(key: where, value: ((x, y), rgb, alpha))
          in expected.entries) {
        final at =
            ((y * pixelsPerDp).floor() * width + (x * pixelsPerDp).floor())
                .round() *
            4;
        expect(
          [colour[at], colour[at + 1], colour[at + 2], colour[at + 3]],
          [
            (rgb.r * 255).round(),
            (rgb.g * 255).round(),
            (rgb.b * 255).round(),
            255,
          ],
          reason: '$where: colour',
        );
        expect(
          monochrome[at + 3] / 255,
          closeTo(alpha, 0.02),
          reason: '$where: themed icon',
        );
      }
    });
  });

  group('the PNG icons (Android 7 and the stores)', () {
    test('are RGBA PNGs without metadata, at their sizes', () {
      for (final MapEntry(key: path, value: width) in pngWidths.entries) {
        final png = readPng(File(path));
        expect((png.width, png.height), (width, width), reason: path);
        // 8-bit RGBA: the corners are transparent.
        expect((png.colourType, png.bitDepth), (6, 8), reason: path);
        expect(png.chunks.toSet(), {'IHDR', 'IDAT', 'IEND'}, reason: path);
      }
    });

    test('show the adaptive icon cut to a circle, as Flutter draws it '
        '(run tool/make_icon_pngs.py after changing it)', () async {
      for (final MapEntry(key: path, value: width) in pngWidths.entries) {
        final expected = await renderRoundIcon(width);
        final actual = await decodePng(path);
        expect(actual.length, expected.length, reason: path);
        // The two renderers smooth edges differently, so compare where
        // Flutter's picture is flat (a pixel the same as the 8 around it).
        // There they agree exactly, and a shape that moved or changed
        // colour changes some of those pixels.
        bool same(Uint8List pixels, int i, int j) =>
            pixels[i] == pixels[j] &&
            pixels[i + 1] == pixels[j + 1] &&
            pixels[i + 2] == pixels[j + 2] &&
            pixels[i + 3] == pixels[j + 3];
        var flat = 0;
        final differing = <String>[];
        for (var y = 1; y < width - 1; y++) {
          for (var x = 1; x < width - 1; x++) {
            final i = (y * width + x) * 4;
            final isFlat = [
              for (var dy = -1; dy <= 1; dy++)
                for (var dx = -1; dx <= 1; dx++)
                  same(expected, i, ((y + dy) * width + x + dx) * 4),
            ].every((s) => s);
            if (!isFlat) continue;
            flat++;
            if (![0, 1, 2, 3].every((c) => actual[i + c] == expected[i + c])) {
              differing.add('($x, $y)');
            }
          }
        }
        // Most of the picture is flat, even at 48 pixels.
        expect(flat / (width * width), greaterThan(0.4), reason: path);
        expect(differing, isEmpty, reason: '$path differs at');
        // Transparent outside the circle, opaque in the middle.
        expect(actual[3], 0, reason: '$path: corner');
        final middle = (width ~/ 2) * width + width ~/ 2;
        expect(actual[middle * 4 + 3], 255, reason: '$path: middle');
      }
    });
  });
}
