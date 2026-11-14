#!/usr/bin/env python3
"""Validate the experiment against an installed archive; never build the runtime."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent


def run(command, **kwargs):
    print('+', ' '.join(map(str, command)), flush=True)
    return subprocess.run(list(map(str, command)), check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prefix', type=Path, required=True)
    parser.add_argument('--cc', default='cc')
    args = parser.parse_args()
    prefix = args.prefix.resolve()
    env = os.environ.copy()
    env['ZIDL_CDR_PREFIX'] = str(prefix)
    # Keep artifacts out of the source tree and make this independent of old builds.
    with tempfile.TemporaryDirectory(prefix='rust cdr consumer ') as tmp:
        tmp = Path(tmp)
        relocated = tmp / 'relocated SDK'
        shutil.copytree(prefix, relocated)
        prefix = relocated
        env['ZIDL_CDR_PREFIX'] = str(prefix)
        env['CARGO_TARGET_DIR'] = str(tmp / 'target')
        manifest = ROOT / 'Cargo.toml'
        cargo = shutil.which('cargo')
        rustc = shutil.which('rustc')
        if not cargo or not rustc:
            parser.error('cargo and rustc must be on PATH')
        run([rustc, '--version'])
        run([cargo, 'test', '--offline', '--manifest-path', manifest], env=env)
        run([cargo, 'build', '--offline', '--lib', '--manifest-path', manifest], env=env)
        rust_layout = subprocess.check_output(
            [cargo, 'run', '--offline', '--quiet', '--manifest-path', str(manifest)], env=env, text=True).split()
        executable = tmp / ('layout.exe' if os.name == 'nt' else 'layout')
        if os.name == 'nt':
            run([args.cc, '/nologo', '/std:c11', '/W3', '/WX',
                 '/I' + str(prefix / 'include'), ROOT / 'layout.c',
                 '/Fo' + str(tmp / 'layout.obj'), '/Fe' + str(executable)])
        else:
            run([args.cc, '-std=c11', '-Wall', '-Wextra', '-Werror', '-I',
                 prefix / 'include', ROOT / 'layout.c', '-o', executable])
        c_layout = subprocess.check_output([str(executable)], text=True).split()
        if rust_layout != c_layout:
            raise RuntimeError(f'ABI layout differs: Rust={rust_layout}, C={c_layout}')
        print('C/Rust sizes, alignments and all cursor field offsets match', flush=True)
        library = tmp / 'target/debug/libcdr_abi_experiment.rlib'
        for name, diagnostic in [('reader_escape', 'E0597'), ('writer_escape', 'E0597'),
                                 ('writer_overlap', 'E0499'), ('reader_mutation', 'E0506')]:
            command = [rustc, '--edition=2021', '--emit=metadata', '--crate-type=bin',
                       '--extern', f'cdr_abi_experiment={library}',
                       '-o', str(tmp / (name + '.rmeta')), str(ROOT / 'compile-fail' / (name + '.rs'))]
            result = subprocess.run(command, text=True, capture_output=True)
            if result.returncode == 0 or f'error[{diagnostic}]' not in result.stderr:
                raise RuntimeError(f'{name}: expected {diagnostic}, got:\n{result.stderr}')
            print(f'{name}: rejected with {diagnostic}', flush=True)
        if sys.platform == 'linux':
            # Rust still needs a linker; forbid native source compilation in its driver.
            tool_dir = tmp / 'consumer tools'
            tool_dir.mkdir()
            for tool in ('cargo', 'rustc', 'rustdoc', 'ld'):
                source = shutil.which(tool)
                if not source:
                    raise RuntimeError(f'{tool} missing for restricted consumer check')
                (tool_dir / tool).symlink_to(source)
            cc = shutil.which(args.cc)
            if not cc:
                raise RuntimeError('linker driver missing')
            marker = tmp / 'linker-called'
            wrapper = tool_dir / 'cc'
            wrapper.write_text(
                f'#!{sys.executable}\n'
                'import os, sys\n'
                'from pathlib import Path\n'
                'if any(a in ("-c", "-S", "-E") or a.endswith(".c") for a in sys.argv[1:]):\n'
                '    raise SystemExit("native compilation forbidden in consumer check")\n'
                f'Path({str(marker)!r}).touch()\n'
                f'os.execv({cc!r}, [{cc!r}, *sys.argv[1:]])\n')
            wrapper.chmod(0o755)
            restricted = env.copy()
            restricted['PATH'] = str(tool_dir)
            restricted['CARGO_TARGET_DIR'] = str(tmp / 'consumer target')
            restricted['RUSTFLAGS'] = '-C linker=cc'
            restricted.pop('RUSTC', None)
            restricted.pop('RUSTDOC', None)
            run([cargo, 'test', '--offline', '--manifest-path', manifest], env=restricted)
            if not marker.is_file():
                raise RuntimeError('restricted check never invoked the linker driver')
            print('Relocated consumer passed without Zig or native source compilation', flush=True)
    print('Rust CDR experiment passed')


if __name__ == '__main__':
    main()
