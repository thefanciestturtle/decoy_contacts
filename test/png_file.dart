// Reading PNG files in tests: the store listing's images and the app's
// icons.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// The CRC-32 of [bytes], as PNG chunks carry it.
int crc32(Uint8List bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}

/// A PNG file's header, and the types of its chunks in order.
typedef Png = ({
  int width,
  int height,
  int bitDepth,
  int colourType,
  List<String> chunks,
});

/// Reads [file] as a PNG file, checked to be whole: the signature, every
/// chunk with its CRC, IHDR first and IEND last, nothing after it, and
/// image data that unpacks to exactly the size the header gives. Each file
/// is read once.
Png readPng(File file) => _pngs.putIfAbsent(file.path, () => _readPng(file));

final _pngs = <String, Png>{};

Png _readPng(File file) {
  final where = file.path;
  final bytes = file.readAsBytesSync();
  const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  expect(bytes.length, greaterThan(signature.length), reason: where);
  expect(bytes.sublist(0, 8), signature, reason: '$where is a PNG file');
  final data = ByteData.sublistView(bytes);
  final chunks = <String>[];
  final idat = BytesBuilder(copy: false);
  Uint8List? header;
  var at = 8;
  while (at + 12 <= bytes.length) {
    final length = data.getUint32(at);
    final type = ascii.decode(bytes.sublist(at + 4, at + 8));
    expect(
      at + 12 + length,
      lessThanOrEqualTo(bytes.length),
      reason: '$where: chunk $type is cut off',
    );
    final typeAndData = Uint8List.sublistView(bytes, at + 4, at + 8 + length);
    expect(
      crc32(typeAndData),
      data.getUint32(at + 8 + length),
      reason: '$where: chunk $type is damaged (CRC)',
    );
    final body = Uint8List.sublistView(bytes, at + 8, at + 8 + length);
    if (type == 'IHDR') header = body;
    if (type == 'IDAT') idat.add(body);
    chunks.add(type);
    at += 12 + length;
    if (type == 'IEND') break;
  }
  expect(at, bytes.length, reason: '$where: nothing after IEND');
  expect(chunks, isNotEmpty, reason: '$where has chunks');
  expect(chunks.first, 'IHDR', reason: '$where starts with IHDR');
  expect(chunks.where((c) => c == 'IHDR'), hasLength(1), reason: where);
  expect(chunks.last, 'IEND', reason: '$where ends with IEND');
  final firstIdat = chunks.indexOf('IDAT');
  expect(firstIdat, isNonNegative, reason: '$where has image data');
  expect(
    chunks.lastIndexOf('IDAT') - firstIdat + 1,
    chunks.where((c) => c == 'IDAT').length,
    reason: '$where: the IDAT chunks come one after another',
  );
  expect(header!.length, 13, reason: '$where: IHDR is 13 bytes');
  final ihdr = ByteData.sublistView(header);
  final png = (
    width: ihdr.getUint32(0),
    height: ihdr.getUint32(4),
    bitDepth: ihdr.getUint8(8),
    colourType: ihdr.getUint8(9),
    chunks: chunks,
  );
  expect(ihdr.getUint8(10), 0, reason: '$where: compression method 0');
  expect(ihdr.getUint8(11), 0, reason: '$where: filter method 0');
  expect(ihdr.getUint8(12), 0, reason: '$where: not interlaced');
  const channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4};
  const bitDepths = {
    0: [1, 2, 4, 8, 16],
    2: [8, 16],
    3: [1, 2, 4, 8],
    4: [8, 16],
    6: [8, 16],
  };
  expect(channels.keys, contains(png.colourType), reason: where);
  expect(
    bitDepths[png.colourType],
    contains(png.bitDepth),
    reason: '$where: a bit depth its colour type allows',
  );
  final bitsPerRow = png.width * channels[png.colourType]! * png.bitDepth;
  // Each row: a filter byte, then the pixels.
  final rowBytes = 1 + (bitsPerRow + 7) ~/ 8;
  expect(
    ZLibCodec().decode(idat.takeBytes()).length,
    png.height * rowBytes,
    reason: "$where: the image data is as big as the header says",
  );
  return png;
}
