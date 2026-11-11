# zidl-cdr-java

A standalone Java CDR runtime, with no JNI, zzdds, or native codec dependency.
API 2 supplies stateless alignment, strings, count/frame/member parsing, optional
scopes, fixed-point operations, key finalization and LE encapsulation lookup
through `io.zidl.cdr.Cdr`. Generated code retains schema traversal, direct primitive
operations, member IDs, declared bounds and canonical key policy.

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
code calls `Cdr.requireApi(2)` when its shared helper class initializes. Compatible
runtime releases continue supporting API 1; a lower API raises `LinkageError`.
A missing JAR produces the JVM's missing-class diagnostic. Match the JAR to the zidl release
that generated the sources, or use an explicitly compatible newer runtime. `API_LEVEL` is the highest
supported generated API; new APIs raise that level while compatible releases continue accepting older
requirements. API 2 still accepts `requireApi(1)`. It is separate from the
implementation version.

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

API 2 also supplies `readCount`, `readFrameEnd`, `readMember`, wide-string
read/write/skip helpers, optional read/write helpers and `OptionalScope`,
`writeFixed`/`readFixed`, `computeKeyHash`, and `detectXcdr`. `readMember` packs the
wire header into the upper 32 bits and the payload end into the lower 32 bits;
`-1` means trailing padding only. Call it with the buffer already limited to the
containing frame. Schema dispatch and member-window restoration remain the caller's
responsibility.

Close an `OptionalScope` in a `finally` block. It restores the parent limit and
advances to the end of an XCDR1 optional value. Wide strings preserve UTF-16 code
units; fixed-point helpers preserve the approximate `double` mapping and expect
validated IDL digit/scale parameters. Encapsulation lookup recognizes LE IDs only;
callers retain complete-header validation. These extraction policies are detailed
in `docs/design/java-cdr-extraction-2.md` in the zidl source.
