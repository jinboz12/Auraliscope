#!/usr/bin/env python3
"""Writes an installer payload: a gzip-compressed odc cpio archive of a directory, every entry owned by root:wheel,
with the files' own modes and no extended attributes.

pkgbuild stores each extended attribute as an AppleDouble "._" entry, and macOS gives every file this build writes a
com.apple.provenance attribute that cannot be removed, so its payloads would put "._" files inside the bundles.
package-installer.sh replaces pkgbuild's payload with this one (and its file list with a matching Bom).

Usage: payload-cpio.py <root directory> <output Payload>
"""
import gzip
import os
import stat
import sys


def header(name, mode, size, mtime, ino, nlink=1):
    name_bytes = name.encode() + b'\0'
    fields = ('070707', '%06o' % 0, '%06o' % (ino & 0o777777), '%06o' % mode, '%06o' % 0, '%06o' % 0,
              '%06o' % nlink, '%06o' % 0, '%011o' % mtime, '%06o' % len(name_bytes), '%011o' % size)
    return ''.join(fields).encode() + name_bytes


def main(root, output):
    entries = ['.']
    for directory, folders, files in os.walk(root):
        folders.sort()
        relative = os.path.relpath(directory, root)
        for name in sorted(folders) + sorted(files):
            if name.startswith('._'):
                raise SystemExit('refusing AppleDouble file %s' % os.path.join(directory, name))
            entries.append('./' + os.path.normpath(os.path.join(relative, name)))
    with gzip.open(output, 'wb', compresslevel=9) as archive:
        for ino, entry in enumerate(entries, start=1):
            path = os.path.join(root, entry)
            info = os.lstat(path)
            mode = info.st_mode
            if stat.S_ISLNK(mode):
                data = os.readlink(path).encode()
            elif stat.S_ISREG(mode):
                with open(path, 'rb') as source:
                    data = source.read()
            elif stat.S_ISDIR(mode):
                data = b''
            else:
                raise SystemExit('unsupported file type: %s' % path)
            archive.write(header(entry, mode, len(data), int(info.st_mtime), ino))
            archive.write(data)
        archive.write(header('TRAILER!!!', 0, 0, 0, 0))


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    main(sys.argv[1], sys.argv[2])
