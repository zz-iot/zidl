#!/usr/bin/env python3
"""Build the standalone Java CDR JAR or run a JDK tool with it on the classpath."""
import argparse
import gzip
import io
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile
import zipfile

PACKAGE = Path(__file__).resolve().parent
SOURCES = PACKAGE / 'src/main/java'


def version_string():
    version_file = PACKAGE / 'VERSION'
    if version_file.exists():
        return version_file.read_text().strip()
    zon = (PACKAGE.parents[1] / 'build.zig.zon').read_text()
    return re.search(r'\.version\s*=\s*"([^"]+)"', zon).group(1)


def manifest_line(key, value):
    raw = (key + ': ' + str(value)).encode('ascii')
    pieces = [raw[:70]]
    raw = raw[70:]
    while raw:
        pieces.append(b' ' + raw[:69])
        raw = raw[69:]
    return b'\r\n'.join(pieces) + b'\r\n'


def build(args):
    version = args.version or version_string()
    if not re.fullmatch(r'[0-9][0-9A-Za-z.+-]*', version):
        raise ValueError('invalid runtime version')
    source = SOURCES / 'io/zidl/cdr/Cdr.java'
    api = int(re.search(r'API_LEVEL = (\d+)', source.read_text()).group(1))
    with tempfile.TemporaryDirectory(prefix='zidl-cdr-java-') as temp:
        classes = Path(temp) / 'classes'
        subprocess.run([args.javac, '--release', '8', '-encoding', 'UTF-8', '-g:none',
                        '-Xlint:all', '-Xlint:-options', '-Werror', '-d', str(classes),
                        *map(str, sorted(SOURCES.rglob('*.java')))], check=True)
        manifest = b''.join(manifest_line(k, v) for k, v in [
            ('Manifest-Version', '1.0'), ('Implementation-Title', 'zidl-cdr-java'),
            ('Implementation-Version', version), ('Zidl-Cdr-Api-Level', api)]) + b'\r\n'
        license_file = PACKAGE / 'LICENSE'
        if not license_file.exists():
            license_file = PACKAGE.parents[1] / 'LICENSE'
        entries = {'META-INF/MANIFEST.MF': manifest,
                   'META-INF/LICENSE': license_file.read_bytes()}
        entries.update((p.relative_to(classes).as_posix(), p.read_bytes())
                       for p in sorted(classes.rglob('*.class')))
        output = Path(args.output)
        output.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as jar:
            for name, data in entries.items():
                info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                info.create_system = 3
                info.external_attr = 0o100644 << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                jar.writestr(info, data, compresslevel=9)


def source_archive(args):
    version = args.version or version_string()
    if not re.fullmatch(r'[0-9][0-9A-Za-z.+-]*', version):
        raise ValueError('invalid runtime version')
    files = {p.relative_to(PACKAGE).as_posix(): p.read_bytes()
             for directory in ['src'] for p in sorted((PACKAGE / directory).rglob('*.java'))}
    for name in ['README.md', 'build.py', 'test.py']:
        files[name] = (PACKAGE / name).read_bytes()
    license_file = PACKAGE / 'LICENSE'
    files['LICENSE'] = (license_file if license_file.exists() else PACKAGE.parents[1] / 'LICENSE').read_bytes()
    files['VERSION'] = (version + '\n').encode('ascii')
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open('wb') as raw, gzip.GzipFile(filename='', mode='wb', fileobj=raw, mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode='w') as archive:
            for name, data in sorted(files.items()):
                info = tarfile.TarInfo('zidl-cdr-java-' + version + '/' + name)
                info.size = len(data)
                info.mode = 0o644
                archive.addfile(info, io.BytesIO(data))


def run(args):
    command = args.command
    if command and command[0] == '--':
        command = command[1:]
    if not command:
        raise ValueError('a JDK tool command is required after --')
    jar = str(Path(args.runtime).resolve())
    if not Path(jar).is_file():
        raise ValueError('runtime JAR does not exist: ' + jar)
    for option in ('-cp', '-classpath', '--class-path'):
        if option in command:
            index = command.index(option) + 1
            if index == len(command):
                raise ValueError('missing classpath')
            command[index] += os.pathsep + jar
            break
    else:
        command[1:1] = ['-cp', jar]
    return subprocess.run(command).returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='action', required=True)
    builder = commands.add_parser('build')
    builder.add_argument('--javac', default='javac')
    builder.add_argument('--version')
    builder.add_argument('--output', required=True)
    source = commands.add_parser('source')
    source.add_argument('--version')
    source.add_argument('--output', required=True)
    runner = commands.add_parser('run')
    runner.add_argument('--runtime', required=True)
    runner.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    try:
        if args.action == 'run':
            return run(args)
        return source_archive(args) if args.action == 'source' else build(args)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    sys.exit(main())
