# zidl-cdr-java

A standalone Java CDR runtime, with no JNI, zzdds, or native codec dependency.
The first API supplies stateless alignment and narrow UTF-8 string operations
through `io.zidl.cdr.Cdr`. Generated code retains schema traversal and direct
primitive buffer operations. Optional scopes, framing, wide strings, fixed-point
and key finalization remain generated in this first extraction.

Build with Python 3.12+ and JDK 9+ (JDK 21 is used in CI):

```sh
python3 packages/zidl-cdr-java/build.py build --output zidl-cdr-java.jar
python3 packages/zidl-cdr-java/test.py --zidl zig-out/bin/zidl
```

From a standalone source archive, use `python3 build.py build --output runtime.jar`.
No Zig or C compiler is needed. The JAR targets Java 8 bytecode and APIs. A source
rebuild with the same JDK/Python toolchain produces identical JAR bytes; timestamps, entry
order, permissions and manifest metadata are fixed. `--version` overrides the
checkout/archive version for packaging.

`zig build java-runtime --prefix <install>` installs a versioned JAR under
`<install>/share/java/`. Ordinary `zig build` only installs the CLI and does not
require a JDK. Zidl releases attach the platform-independent versioned JAR and
source archive separately from native CLI archives. There is no Maven publication.

Add the same JAR to compile and runtime classpaths:

```sh
javac -encoding UTF-8 -cp zidl-cdr-java.jar -d classes generated/*.java MyApp.java
java -cp classes:zidl-cdr-java.jar MyApp
```

Use `;` instead of `:` on Windows. `--no-typesupport` output remains runtime-free.
Previously generated inline codecs remain usable without the JAR. Newly generated
code calls `Cdr.requireApi(1)` when its shared helper class initializes. Compatible
runtime releases retain API 1; a lower API raises `LinkageError`. A missing JAR
produces the JVM's missing-class diagnostic. Match the JAR to the zidl release
that generated the sources, or use an explicitly compatible newer runtime. `API_LEVEL` is the highest supported generated API;
new APIs raise that level while compatible releases continue accepting older
requirements. It is separate from the implementation version.

| Operation | Buffer effect |
|---|---|
| `align(buffer, base, alignment)` | Advance over padding without changing bytes |
| `alignKey(buffer, base, alignment)` | Write zero padding |
| `stringEnd(buffer, base)` | Consume aligned length header, validate body/NUL, return end; leave position at body start |
| `readString(buffer, base)` | Decode and advance through the final NUL |
| `skipString(buffer, base)` | Validate and advance without decoding/allocation |
| `writeString(buffer, base, value)` | Check capacity, then write aligned UTF-8 count, body and NUL |

Operations preserve the supplied byte order and use the supplied CDR alignment
origin. `align` only advances; `alignKey` writes zero padding. Narrow strings use
Java UTF-8 conversion, including replacement of malformed input and unpaired
surrogates. Lengths and NUL terminators are checked before body allocation; write
capacity failures preserve position and bytes. The cursor/error contract remains
that documented in `docs/design/java-cdr-string-validation.md` in the zidl source.
