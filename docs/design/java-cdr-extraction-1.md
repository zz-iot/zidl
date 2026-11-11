# First shared Java CDR extraction

The standalone `packages/zidl-cdr-java` runtime now owns ordinary alignment,
zero-filled canonical alignment, and validated narrow UTF-8 string operations.
It is pure Java, targets Java 8 APIs/bytecode, and has no dependency on zzdds,
JNI/FFM, Zig or the native codec. Applications need only prebuilt zidl, the JAR
and JDK tools. Building the JAR from its source archive needs Python and a JDK.

`io.zidl.cdr.Cdr` supplies `align`, `alignKey`, `stringEnd`, `writeString`,
`readString`, `skipString` and `requireApi`. The supplied buffer retains its byte
order, alignment origin, cursor and exception contracts from the preceding
correctness checkpoints. Java UTF-8 replacement is now an explicit preserved
policy: malformed UTF-8 decodes with replacement and unpaired UTF-16 surrogates
encode using Java's replacement byte. Wide-string code units and approximate
fixed-point mapping remain unchanged and generated.

Generated single-file helpers and split public utility helpers forward extracted
operations to the runtime. Existing public codec signatures and observable
helper names remain. Helper-class initialization calls `requireApi(1)`; lower API
levels raise `LinkageError`. Additive compatible releases retain API 1. Runtime
implementation versions match zidl's version; no Maven artifact is published.
New generated codec sources need the JAR on compilation and execution classpaths.
Old inline sources keep working without it, and `--no-typesupport` stays free of
runtime references. No second permanent inline generator mode was added.

`zig build java-runtime --prefix <install>` installs the versioned JAR under
`share/java/`. Ordinary CLI builds do not depend on this target or require Java.
The release workflow builds one platform-independent JAR and source archive,
attaches both to the release, and leaves native CLI archive layouts intact.
The standalone source rebuild reproduces identical JAR bytes with the same
compiler. Metadata records implementation version and API level; class entries
use Java 8 version 52 and contain no debug paths or timestamps.

Zidl's standalone, golden, key, optional, known-answer and JNI Java build steps
now include the JAR on both classpaths. CI explicitly supplies a JDK/Python and
adds runtime checks on Java 8 and 21. Fresh-consumer tests use an empty PATH,
absolute prebuilt zidl/JDK paths and the JAR, proving no C/Zig compiler or native
codec is used. Tests cover normal/malformed strings, alignment variants, Unicode
replacement, API-level rejection, missing JAR diagnostics, key hash bytes, source
rebuilds and all three output modes.

Optional scopes, DHEADER/EMHEADER and collection machinery, wide strings, fixed
helpers, hash finalization and encapsulation remain generated. They can move in
subsequent slices against the existing vectors and boundary fixtures. Zzdds
Java SDK installation, example classpaths and smoke/loan integration must pick up
the JAR when upgrading to a zidl release containing this extraction; the current
pinned release still generates inline codecs. This checkpoint does not claim
that downstream migration or the full Java runtime plan is complete.

The separately recorded split interface/JNI implementation qualification issue
is unchanged. It does not block standalone codec consumption.

## Measurement checkpoint

The [separate extraction snapshot](../../test/java-cdr-baseline/extraction-1.json)
compares the cached output-parity generator with this first extraction, using the
same fixture and compiler. The original pre-correctness baseline stays unchanged.

| Mode | Generated source before/after | Generated classes before/after | Classes including runtime after |
|---|---:|---:|---:|
| Single | 42,866 / 41,331 bytes | 31,008 / 30,391 bytes | 32,666 bytes |
| Split | 41,248 / 39,713 bytes | 29,708 / 29,091 bytes | 31,366 bytes |

The JAR is 5,678 compressed bytes including the license; its class is 2,275 bytes.
One small IDL input therefore has a larger total class footprint after adding
the runtime despite smaller generated classes. Sharing across inputs avoids
repeating the extracted bodies, but no general application-size reduction is
claimed. The one-fork warm measurements ran alongside a native test build and
are diagnostic only; they establish no performance improvement. Allocation and
cold-start measurements remain necessary before making such claims.
