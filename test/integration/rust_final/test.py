#!/usr/bin/env python3
"""Compile generated Rust and check explicit unsupported-mapping diagnostics."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zidl', type=Path, required=True)
    parser.add_argument('--prefix', type=Path, required=True)
    args = parser.parse_args()
    exe = str(args.zidl.resolve())
    env = os.environ.copy()
    env['ZIDL_CDR_PREFIX'] = str(args.prefix.resolve())
    with tempfile.TemporaryDirectory(prefix='generated rust codecs ') as tmp:
        root = Path(tmp)
        subprocess.run([exe, '-b', 'rust', '-o', str(root), str(ROOT/'shapes.idl')], check=True)
        (root/'main.rs').write_text((ROOT/'test.rs').read_text())
        runtime = REPO/'packages/zidl-cdr-rust'
        (root/'Cargo.toml').write_text('[package]\nname="generated-rust-check"\nversion="0.0.0"\nedition="2021"\n'
            '[[bin]]\nname="check"\npath="main.rs"\n[dependencies]\nzidl-cdr-rust={path='+json.dumps(str(runtime))+'}\n')
        subprocess.run(['cargo', 'run', '--offline', '--manifest-path', str(root/'Cargo.toml')], env=env, check=True)
        declarations = root/'declarations'
        declarations.mkdir()
        subprocess.run([exe, '-b', 'rust', '--no-typesupport', '-o', str(declarations), str(ROOT/'shapes.idl')], check=True)
        subprocess.run(['rustc', '--edition=2021', '--crate-type=lib', '--emit=metadata',
                        '-o', str(root/'declarations.rmeta'), str(declarations/'shapes.rs')], check=True)
        cases = [
            ('string', 'struct S { string value; };'),
            ('wstring', 'struct S { wstring value; };'),
            ('sequence', 'struct S { sequence<long> value; };'),
            ('map', 'struct S { map<long,long> value; };'),
            ('fixed', 'struct S { fixed<8,2> value; };'),
            ('wchar', 'struct S { wchar value; };'),
            ('long-double', 'struct S { long double value; };'),
            ('optional', 'struct S { @optional long value; };'),
            ('key', 'struct S { @key long value; };'),
            ('default', 'struct S { @default(7) long value; };'),
            ('appendable', '@appendable struct S { long value; };'),
            ('mutable', '@mutable struct S { long value; };'),
            ('inheritance', 'struct Base { long value; }; struct S : Base { long extra; };'),
            ('union', 'union U switch(long) { case 0: long value; };'),
            ('bitmask', 'bitmask Bits { A, B };'),
            ('enum-width', '@bit_bound(8) enum E { A, B };'),
            ('enum-method', 'enum E { encode, decode };'),
            ('reserved', 'struct Self { long value; };'),
            ('constant', 'const long VALUE = 7;'),
            ('enum-array', 'enum E { A,B }; struct S { E values[2]; };'),
            ('struct-array', 'struct T { long value; }; struct S { T values[2]; };'),
            ('array-alias', 'enum E { A,B }; typedef E Row[2]; typedef Row Matrix[2]; struct S { Matrix values; };'),
        ]
        for name, source in cases:
            path = root/(name+'.idl'); path.write_text(source)
            for mode in ([], ['--no-typesupport']):
                out = root/(name+str(len(mode))); out.mkdir()
                result = subprocess.run([exe, '-b', 'rust', *mode, '-o', str(out), str(path)], capture_output=True, text=True)
                assert result.returncode and 'UnsupportedRustMapping' in result.stderr, (name,result.stderr)
                assert not list(out.iterdir()), (name,list(out.iterdir()))
        for flags in [['--split-files'], ['--generate-interfaces'], ['--generate-zzdds-wrappers'],
                      ['--type-prefix','Rust_'], ['--default-extensibility','appendable']]:
            option = flags[0]
            out = root/option[2:]; out.mkdir()
            result = subprocess.run([exe,'-b','rust',*flags,'-o',str(out),str(ROOT/'shapes.idl')],capture_output=True,text=True)
            assert result.returncode and 'UnsupportedRustMapping' in result.stderr, (option,result.stderr)
            assert not list(out.iterdir())
        (root/'external.idl').write_text('module External { struct T { long value; }; };')
        source = root/'imported.idl'
        source.write_text('import \"external.idl\"; module Own { struct S { External::T value; }; };')
        out = root/'import-output'; out.mkdir()
        result = subprocess.run([exe,'-b','rust','-o',str(out),str(source)],capture_output=True,text=True)
        assert result.returncode and 'UnsupportedRustMapping' in result.stderr, result.stderr
        assert not list(out.iterdir())
    print('Rust declarations and 50 unsupported mapping/option cases passed')


if __name__ == '__main__':
    main()
