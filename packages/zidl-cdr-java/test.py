#!/usr/bin/env python3
"""Check JAR reproducibility, Java compatibility, and native-free consumption."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile

PACKAGE = Path(__file__).resolve().parent


def run(command, **kwargs):
    subprocess.run(list(map(str, command)), check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--javac', default=shutil.which('javac'))
    parser.add_argument('--java', default=shutil.which('java'))
    parser.add_argument('--zidl', type=Path)
    args = parser.parse_args()
    if not args.javac or not args.java:
        parser.error('javac and java are required')
    javac, java = Path(args.javac).resolve(), Path(args.java).resolve()
    env = dict(os.environ, PATH='')
    with tempfile.TemporaryDirectory(prefix='java-cdr-consumer-') as temp:
        directory = Path(temp)
        jar = directory / 'runtime.jar'
        for output in [jar, directory / 'repeat.jar']:
            run([sys.executable, PACKAGE / 'build.py', 'build', '--javac', javac,
                 '--version', '1.2.3', '--output', output], env=env)
        assert jar.read_bytes() == (directory / 'repeat.jar').read_bytes()
        with zipfile.ZipFile(jar) as archive:
            manifest = archive.read('META-INF/MANIFEST.MF')
            assert b'Implementation-Version: 1.2.3\r\n' in manifest
            assert b'Zidl-Cdr-Api-Level: 1\r\n' in manifest
            assert archive.read('META-INF/LICENSE')
            for name in archive.namelist():
                if name.endswith('.class'):
                    assert archive.read(name)[:8] == b'\xca\xfe\xba\xbe\x00\x00\x00\x34'
        classes = directory / 'classes'
        run([javac, '--release', '8', '-encoding', 'UTF-8', '-Xlint:-options', '-Xlint:all', '-Werror',
             '-cp', jar, '-d', classes,
             PACKAGE / 'src/test/java/io/zidl/cdr/CdrTest.java'], env=env)
        run([java, '-cp', str(classes) + os.pathsep + str(jar), 'io.zidl.cdr.CdrTest'], env=env)
        source = directory / 'source.tar.gz'
        run([sys.executable, PACKAGE / 'build.py', 'source', '--version', '1.2.3', '--output', source])
        with tarfile.open(source) as archive:
            archive.extractall(directory / 'source', filter='data')
        run([sys.executable, directory / 'source/zidl-cdr-java-1.2.3/build.py',
             'build', '--javac', javac, '--output', directory / 'from-source.jar'], env=env)
        assert hashlib.sha256(jar.read_bytes()).digest() == hashlib.sha256((directory / 'from-source.jar').read_bytes()).digest()
        if args.zidl:
            zidl = args.zidl.resolve()
            if not zidl.exists() and os.name == 'nt':
                zidl = zidl.with_suffix('.exe')
            model = directory / 'sample.idl'
            model.write_text('@final struct Greeting { @key string text; long value; };\n', encoding='utf-8')
            consumer = directory / 'Consumer.java'
            consumer.write_text('''import java.nio.*;
import java.util.Arrays;
public class Consumer {
 public static void main(String[] args) throws Exception {
  Class<?> type=Class.forName(args[0]+"Greeting"); Object value=type.getConstructor().newInstance();
  type.getMethod("set_text",String.class).invoke(value,"é"); type.getMethod("set_value",int.class).invoke(value,7);
  ByteBuffer b=ByteBuffer.allocate(32); type.getMethod("serialize",ByteBuffer.class,int.class,int.class).invoke(value,b,0,2); b.flip();
  Object out=type.getMethod("deserializeFrom",ByteBuffer.class,int.class,int.class).invoke(null,b.asReadOnlyBuffer(),0,2);
  if(!type.getMethod("get_text").invoke(out).equals("é") || !type.getMethod("get_value").invoke(out).equals(7)) throw new AssertionError();
  byte[] expected=java.security.MessageDigest.getInstance("MD5").digest(new byte[]{0,0,0,3,(byte)0xc3,(byte)0xa9,0});
  if(!Arrays.equals((byte[])type.getMethod("computeKeyHash").invoke(value),expected)) throw new AssertionError();
 }
}''', encoding='utf-8')
            older_source = directory / 'older/Cdr.java'
            older_source.parent.mkdir()
            older_source.write_text('package io.zidl.cdr; public final class Cdr { public static void requireApi(int required) { if(required != 1) throw new AssertionError(); throw new LinkageError("runtime provides 0"); } }', encoding='utf-8')
            older_classes = directory / 'older/classes'
            run([javac, '--release', '8', '-Xlint:-options', '-d', older_classes, older_source], env=env)
            for mode in range(3):
                data_only = directory / ('data-only-' + str(mode))
                run([zidl, '-b', 'java', '--no-typesupport', *(['--split-files'] if mode else []),
                     *(['--java-package', 'consumer'] if mode == 1 else []), '-o', data_only, model], env=env)
                assert not (data_only / 'SampleCdrUtils.java').exists()
                assert all('io.zidl.cdr' not in source.read_text(encoding='utf-8') for source in data_only.glob('*.java'))
                run([javac, '--release', '8', '-encoding', 'UTF-8', '-Xlint:-options',
                     '-d', data_only / 'classes', *sorted(data_only.glob('*.java'))], env=env)
                generated = directory / ('generated-' + str(mode))
                run([zidl, '-b', 'java', *(['--split-files'] if mode else []),
                     *(['--java-package', 'consumer'] if mode == 1 else []), '-o', generated, model], env=env)
                target = generated / 'classes'
                run([javac, '--release', '8', '-encoding', 'UTF-8', '-Xlint:-options',
                     '-cp', jar, '-d', target, *sorted(generated.glob('*.java')), consumer], env=env)
                cp = str(target) + os.pathsep + str(jar)
                prefix = ['Sample$', 'consumer.', ''][mode]
                run([java, '-cp', cp, 'Consumer', prefix], env=env)
                missing = subprocess.run([java, '-cp', target, 'Consumer', prefix], env=env,
                                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                assert missing.returncode != 0 and b'io/zidl/cdr/Cdr' in missing.stderr
                older = subprocess.run([java, '-cp', str(target) + os.pathsep + str(older_classes),
                                        'Consumer', prefix], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                assert older.returncode != 0 and b'runtime provides 0' in older.stderr
    print('Java CDR JAR, source rebuild, API, and native-free checks passed')


if __name__ == '__main__':
    main()
