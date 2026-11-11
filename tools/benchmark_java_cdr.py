#!/usr/bin/env python3
"""Audit inline Java helpers and measure standalone codec size and warm timings."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / 'test/java-cdr-baseline'


def run(args, **kwargs):
    try:
        return subprocess.run([str(arg) for arg in args], check=True, text=True,
                              capture_output=True, timeout=120, **kwargs).stdout
    except subprocess.CalledProcessError as error:
        raise RuntimeError(error.stderr) from error


def helper_blocks(source):
    pattern = r'(?m)^\s*(?:public|private) static (?:final class|[\w.\[\]]+) (_[cC]dr\w+)\b[^\n]*\{'
    blocks = []
    for match in re.finditer(pattern, source):
        start = source.index('{', match.start())
        depth = 1
        end = start + 1
        quoted = None
        while depth:
            char = source[end]
            if quoted:
                if char == '\\':
                    end += 2
                    continue
                if char == quoted:
                    quoted = None
            elif char in '\"\'':
                quoted = char
            elif char == '{':
                depth += 1
            elif char == '}':
                depth -= 1
            end += 1
        blocks.append((match.group(1), source[match.start():end]))
    return blocks


def measure(zidl, directory, mode, flags, runtime=None):
    generated = directory / mode
    generated.mkdir()
    run([zidl, '-b', 'java', '--java-package', 'javaaudit.' + mode,
         *flags, '-o', generated, FIXTURE / 'model.idl'])
    files = sorted(generated.glob('*.java'))
    blocks = [block for file in files for block in helper_blocks(file.read_text())]
    data = {'files': len(files), 'source_bytes': sum(p.stat().st_size for p in files),
            'helper_declarations': len(blocks),
            'helper_bytes': sum(len(body.encode()) for _, body in blocks)}
    if '--generate-zzdds-wrappers' in flags:
        data['classes'] = None
        return data
    classes = generated / 'classes'
    classes.mkdir()
    runtime_cp = ['-cp', runtime] if runtime and '--no-typesupport' not in flags else []
    run(['javac', '--release', '8', '-Xlint:-options', '-Xlint:unchecked', '-Werror', *runtime_cp, '-d', classes, *files])
    classpath = str(classes) + (os.pathsep + str(runtime) if runtime else '')
    compiled = list(classes.rglob('*.class'))
    data.update(classes=len(compiled), class_bytes=sum(p.stat().st_size for p in compiled))
    if '--no-typesupport' not in flags:
        template = (FIXTURE / 'Benchmark.java.in').read_text()
        prefix = 'javaaudit.' + mode + ('.Model' if '--split-files' not in flags else '')
        imports = '\n'.join(f'import {prefix}.{name};' for name in ['Scalar', 'Text', 'Frame', 'Tagged'])
        benchmark = generated / 'Benchmark.java'
        benchmark.write_text(template.replace('@IMPORTS@', imports))
        run(['javac', '--release', '8', '-Xlint:-options', '-cp', classpath, '-d', classes, benchmark])
        probe = generated / 'Probe.java'
        probe.write_text((FIXTURE / 'Probe.java.in').read_text())
        run(['javac', '--release', '8', '-Xlint:-options', '-d', classes, probe])
        helpers = 'javaaudit.' + mode + ('.ModelCdrUtils' if '--split-files' in flags else '.Model')
        data['observations'] = [json.loads(line) for line in
            run(['java', '-cp', classpath, 'Probe', helpers, prefix + ('.Window' if '--split-files' in flags else '$Window')]).splitlines()]

    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zidl', required=True, type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--runtime-jar', type=Path)
    parser.add_argument('--warmup', type=int, default=200_000)
    parser.add_argument('--iterations', type=int, default=500_000)
    parser.add_argument('--forks', type=int, default=3)
    args = parser.parse_args()
    if min(args.warmup, args.iterations, args.forks) <= 0:
        parser.error('warmup, iterations and forks must be positive')
    zidl = args.zidl.resolve()
    runtime = args.runtime_jar.resolve() if args.runtime_jar else None
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='java-cdr-', dir=args.output) as temp:
        directory = Path(temp)
        report = {'generator': run([zidl, '--version']).strip(),
                  'revision': run(['git', '-C', ROOT, 'rev-parse', 'HEAD']).strip(),
                  'working_tree_modified': bool(run(['git', '-C', ROOT, 'status', '--porcelain', '--', 'src/backend/java.zig', 'packages/zidl-cdr-java']).strip()),
                  'java': subprocess.run(['java', '-version'], text=True, capture_output=True,
                                         check=True, timeout=30).stderr.strip(),
                  'platform': platform.platform(), 'warmup': args.warmup,
                  'forks': args.forks, 'sizes': {}, 'timings': [],
                  'javac_target': 8, 'java_vm_flags': ['-Xms128m', '-Xmx128m'],
                  'generator_sha256': hashlib.sha256(zidl.read_bytes()).hexdigest(),
                  'fixture_sha256': hashlib.sha256((FIXTURE / 'model.idl').read_bytes()).hexdigest(),
                  'benchmark_sha256': hashlib.sha256((FIXTURE / 'Benchmark.java.in').read_bytes()).hexdigest()}
        modes = {'single': [], 'split': ['--split-files'],
                 'single_types': ['--no-typesupport'],
                 'split_types': ['--split-files', '--no-typesupport'],
                 'single_wrappers': ['--generate-zzdds-wrappers'],
                 'split_wrappers': ['--split-files', '--generate-zzdds-wrappers']}
        for mode, flags in modes.items():
            report['sizes'][mode] = measure(zidl, directory, mode, flags, runtime)
        for fork in range(args.forks):
            for mode in ['single', 'split']:
                for shape, versions in [('scalar', [1, 2]), ('frame', [1, 2]), ('tagged', [2]), ('keys', [2])]:
                    for version in versions:
                        result = json.loads(run(['java', '-Xms128m', '-Xmx128m', '-cp',
                            str(directory / mode / 'classes') + (os.pathsep + str(runtime) if runtime else ''), 'Benchmark', shape, version,
                            args.warmup, args.iterations]))
                        result.update(mode=mode, fork=fork)
                        report['timings'].append(result)

        report['compilation_probes'] = {}
        for name, idl, flags in [
            ('split_default_package', '@final struct Simple { long value; };', []),
            ('split_fixed', '@final struct Price { fixed<8,2> amount; };', ['--java-package', 'javaaudit.fixed'])]:
            probe = directory / name
            probe.mkdir()
            source = probe / 'probe.idl'
            source.write_text(idl)
            run([zidl, '-b', 'java', '--split-files', *flags, '-o', probe, source])
            result = subprocess.run(['javac', '--release', '8', '-Xlint:-options', '-d', str(probe / 'classes'),
                *(['-cp', str(runtime)] if runtime else []), *map(str, sorted(probe.glob('*.java')))], text=True, capture_output=True, timeout=120)
            report['compilation_probes'][name] = {'returncode': result.returncode, 'diagnostic': result.stderr.replace(str(directory), '<generated>')}
        if runtime:
            with zipfile.ZipFile(runtime) as archive:
                runtime_classes = sum(item.file_size for item in archive.infolist() if item.filename.endswith('.class'))
            report['runtime_jar'] = {'bytes': runtime.stat().st_size, 'class_bytes': runtime_classes, 'sha256': hashlib.sha256(runtime.read_bytes()).hexdigest()}
            for mode, data in report['sizes'].items():
                if data.get('class_bytes') is not None:
                    data['application_class_bytes'] = data['class_bytes'] + (runtime_classes if 'types' not in mode else 0)
        path = args.output / 'baseline.json'
        path.write_text(json.dumps(report, indent=2) + '\n')
        print(path)


if __name__ == '__main__':
    main()
