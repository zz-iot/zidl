# Native boolean union dispatch

C and C++ switches on boolean union discriminators now explicitly cast the
selector to int. The shared helper resolves typedef aliases first and changes
only boolean selectors. This avoids strict `-Wswitch-bool` diagnostics without
changing discriminator storage, arm labels or any ordinary/canonical wire bytes.
Unary plus alone still triggers the warning with the tested Clang compiler.

The change covers ordinary writers/readers, skip traversal, mutable selection
checks, canonical-key holders, C cleanup, and C++ active-member construction,
destruction, copy and move helpers. Other discriminator types retain their
existing expressions.

`test-native-boolean-union` compiles and runs C99, C++ STL and C++ PMR consumers,
in single and split output modes, with `-Wall -Wextra -Werror`. Tests exercise
alias chains, both boolean values, default-first and exhaustive arms, owning
payloads, copy/move/assignment, counting writers, truncations and skip traversal.
Final/appendable unions cover XCDR1/XCDR2 in both byte orders; mutable unions
cover XCDR2. GCC/G++ strict compilation was independently checked in all six
output modes; execution uses the normal Zig/Clang build targets.

The split fixture uses top-level types. An unrelated existing issue was observed
with modular C++ split output: per-type declarations are emitted outside their
qualified namespace. Fixing namespace preservation requires its own scoped
reproducer and is not part of boolean dispatch.
