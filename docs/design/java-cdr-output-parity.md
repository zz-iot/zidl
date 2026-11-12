# Java codec output-mode parity

This follows the [collection checkpoint](java-cdr-collection-bounds.md) and closes
the split-output compilation gaps found during the runtime audit.

Single-file and split-file generation now use the same fixed-point helper
emitter. Split codecs can compile fixed fields and use the existing packed-BCD
read/write implementation. The approximate `double` mapping, intermediate `long`
arithmetic, rounding and BCD acceptance behavior are unchanged; this does not add
exact decimal arithmetic or wider numeric guarantees.

Split bitsets now import the CDR helpers needed by their alignment operations,
just like split structs, unions and exceptions.

When `--java-package` is set, helpers remain in that package with the generated
types. Without it, user types remain in Java's default package, while
`<Stem>CdrUtils` declares `package zidl.generated`. The types can legally statically
import this helper class; Java does not allow static imports from the default
package. Source filenames and their flat output-directory layout are unchanged.
Compile all generated sources with `javac -d <classes> ...`; javac writes the
helper class beneath `zidl/generated` in the classes directory. That directory's
root belongs on the runtime classpath alongside the default-package classes.

No helper file or import is added by `--no-typesupport`. This namespace is for
generated per-input helpers; it is not the planned shared runtime library.

`test-java-cdr-validation` now runs all five fixtures in single-file, named split,
and default-package split modes. The new parity test checks independent BCD
bytes, positive/negative and odd/even digit counts, fixed reads/writes/skips under
XCDR1 and XCDR2, an aligned bitset round trip, and present/absent optional-field round trips. The existing string, frame,
member and collection fixtures also run in all three modes.

A broader compile of the split goldens also found a separate interface-stub gap:
optional `--generate-interfaces` outputs such as `GreeterImpl.java` still reference the
single-file interface name (`Types.Greeter`) instead of the split top-level
interface. This checkpoint covers generated types and codecs; implementation
stub qualification remains a follow-up and does not add a codec-runtime
requirement.
