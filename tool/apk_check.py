"""Checks on release APKs, for the scripts in tool/. Run with python3 -I.

  apk_check.py signature APK
      Prints the signature schemes the APK is signed with, one per line
      ("v1", "v2", "v3", "v3.1"), and any other block in its signing block
      by name ("padding", "dependency-info", "source-stamp") or hex ID.
      Prints nothing for an unsigned APK.

  apk_check.py home-paths APK [TEXT...]
      Fails, listing them, if any file in the APK names a home folder
      (in /home, /var/home, /Users or /root) other than /home/vagrant/, the
      release build sandbox's, or holds any of the TEXTs of 4 characters or
      more (say this computer's home folder and name).

  apk_check.py same APK1 APK2
      Fails unless the two are the same file; lists the files inside that
      differ.

  apk_check.py only-signature-added SIGNED UNSIGNED
      Fails unless SIGNED is UNSIGNED with a signing block added (after
      zeros that align it, as apksigner does) and nothing else changed:
      what F-Droid needs to copy the signature onto its own build of the
      same source.
"""

import re
import struct
import sys
import zipfile

# IDs of the blocks in an APK signing block.
BLOCK_NAMES = {
    0x7109871A: 'v2',
    0xF05368C0: 'v3',
    0x1B93AD61: 'v3.1',
    0x42726577: 'padding',
    # Google's dependency metadata, encrypted for Google Play.
    0x504B4453: 'dependency-info',
    0x6DFF800D: 'source-stamp',
}

MAGIC = b'APK Sig Block 42'

# Where home folders are, and the one a release build may name: the
# sandbox's.
HOME_FOLDERS = rb'/home/|/var/home/|/Users/|/root/'
ALLOWED_HOME = b'/home/vagrant/'


class NotAnApk(Exception):
    pass


def _central_directory(data):
    """The offset of the ZIP central directory, and of the field in the end
    of central directory record that holds it."""
    eocd = data.rfind(b'PK\x05\x06')
    if eocd < 0 or len(data) - eocd < 22:
        raise NotAnApk('not a ZIP file')
    field = eocd + 16
    (offset,) = struct.unpack('<I', data[field:field + 4])
    if offset > eocd:
        raise NotAnApk('ZIP central directory out of place')
    return offset, field


def _signing_block(data):
    """(start, end, [(ID, value)]) of the APK signing block, which ends where
    the central directory starts; None if there is none."""
    cd, _ = _central_directory(data)
    if cd < 24 or data[cd - 16:cd] != MAGIC:
        return None
    (size,) = struct.unpack('<Q', data[cd - 24:cd - 16])
    start = cd - size - 8
    if start < 0 or struct.unpack('<Q', data[start:start + 8])[0] != size:
        raise NotAnApk('broken APK signing block')
    pairs = []
    pos = start + 8
    while pos < cd - 24:
        (length,) = struct.unpack('<Q', data[pos:pos + 8])
        if length < 4 or pos + 8 + length > cd - 24:
            raise NotAnApk('broken APK signing block')
        (block_id,) = struct.unpack('<I', data[pos + 8:pos + 12])
        pairs.append((block_id, data[pos + 12:pos + 8 + length]))
        pos += 8 + length
    return start, cd, pairs


def signature(path):
    data = open(path, 'rb').read()
    found = []
    with zipfile.ZipFile(path) as apk:
        # v1 (JAR signing): signature files in META-INF.
        if any(re.fullmatch(r'META-INF/[^/]+\.(SF|RSA|DSA|EC)', name)
               for name in apk.namelist()):
            found.append('v1')
    block = _signing_block(data)
    if block:
        for block_id, _ in block[2]:
            found.append(BLOCK_NAMES.get(block_id, '%#010x' % block_id))
    for name in found:
        print(name)
    return 0


def home_paths(path, *texts):
    words = [text.encode() for text in texts if len(text) >= 4]
    bad = []

    def found(info, content, start):
        text = re.match(rb'[\x21-\x7e]{0,120}', content[start:]).group()
        bad.append('%s: %s' % (info.filename,
                               text.decode('ascii', 'replace')))

    with zipfile.ZipFile(path) as apk:
        for info in apk.infolist():
            content = apk.read(info)
            for match in re.finditer(HOME_FOLDERS, content):
                if not content.startswith(ALLOWED_HOME, match.start()):
                    found(info, content, match.start())
            for word in words:
                start = content.find(word)
                if start >= 0:
                    found(info, content, start)
    if bad:
        print('names a home folder other than %s, or this computer:'
              % ALLOWED_HOME.decode(), file=sys.stderr)
        for line in sorted(set(bad)):
            print('  ' + line, file=sys.stderr)
        return 1
    return 0


def same(path1, path2):
    if open(path1, 'rb').read() == open(path2, 'rb').read():
        return 0

    def contents(path):
        with zipfile.ZipFile(path) as apk:
            return {info.filename: apk.read(info) for info in apk.infolist()}

    files1, files2 = contents(path1), contents(path2)
    differ = sorted(name for name in set(files1) | set(files2)
                    if files1.get(name) != files2.get(name))
    print('%s and %s differ' % (path1, path2), file=sys.stderr)
    if differ:
        for name in differ:
            print('  ' + name, file=sys.stderr)
    else:
        print('  (not in the files they hold: in how they are stored, or in'
              ' the signature)', file=sys.stderr)
    return 1


def only_signature_added(signed_path, unsigned_path):
    signed = open(signed_path, 'rb').read()
    unsigned = open(unsigned_path, 'rb').read()
    block = _signing_block(signed)
    if not block:
        print('%s has no APK signing block' % signed_path, file=sys.stderr)
        return 1
    start, cd, _ = block
    _, field = _central_directory(signed)
    unsigned_cd, _ = _central_directory(unsigned)
    # apksigner pads with zeros before the block, so that it starts at a
    # multiple of 4096 bytes; apksigcopier, which F-Droid copies signatures
    # with, pads the same way. Without the padding and the block, and with
    # the central directory's offset pointing where they started, it must
    # be the unsigned APK.
    stripped = bytearray(signed[:unsigned_cd] + signed[cd:])
    field -= cd - unsigned_cd
    stripped[field:field + 4] = struct.pack('<I', unsigned_cd)
    if unsigned_cd > start or signed[unsigned_cd:start].strip(b'\0') \
            or bytes(stripped) != unsigned:
        print('%s is not %s with only a signature added'
              % (signed_path, unsigned_path), file=sys.stderr)
        return 1
    return 0


def main(argv):
    commands = {
        'signature': (signature, 1),
        'home-paths': (home_paths, 1),
        'same': (same, 2),
        'only-signature-added': (only_signature_added, 2),
    }
    if len(argv) < 2 or argv[1] not in commands \
            or len(argv) - 2 < commands[argv[1]][1] \
            or (argv[1] != 'home-paths'
                and len(argv) - 2 != commands[argv[1]][1]):
        print(__doc__, file=sys.stderr)
        return 2
    function, _ = commands[argv[1]]
    try:
        return function(*argv[2:])
    except (OSError, zipfile.BadZipFile, NotAnApk) as error:
        print('%s: %s' % (argv[2], error), file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
