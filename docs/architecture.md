# zidl — Internal Architecture

This document covers the internal pipeline: how an IDL source file becomes generated
code. It is intended for contributors and for users who need to understand why the
tool behaves as it does.

---

## Pipeline

```
.idl source
  │
  ▼
src/preprocessor.zig   — #include / #define / #ifdef / #if / #pragma
  │
  ▼
src/lexer.zig          — tokenization (keywords, identifiers, literals)
  │
  ▼
src/parser.zig         — recursive descent; one fn per grammar rule (227 rules)
  │
  ▼
src/ast.zig            — tagged-union AST nodes; ArenaAllocator ownership
  │
  ▼
src/semantic/          — scope resolution, const eval, error reporting
  │
  ▼
src/ir/                — clean IR: resolved names, merged modules, typed annotations
  │
  ▼
src/backend/<lang>.zig — code generation
```

Multiple input files are each processed as an independent compilation unit:
the full pipeline (preprocess → parse → semantic → IR → backend) runs once per
file. Types defined in one input file are not visible to another.

---

## src/preprocessor.zig

**Design:** A streaming character source with macro expansion and conditional
compilation. Implements the subset of C preprocessing specified in IDL4 §7.3.

**Key decisions:**
- Processes bytes, not tokens — the lexer runs on the expanded text.
- `#include` files are found via `-I` search paths, read recursively.
- `#pragma keylist`, `#pragma DCPS_DATA_TYPE`, `#pragma DCPS_DATA_KEY` are parsed
  and preserved as `PragmaNode` AST nodes; the IR builder converts them to
  `@key` annotations and `@nested` suppressions.
- `__DATE__` and `__TIME__` expand to UTC C-preprocessor-style strings. CLI runs honor
  `SOURCE_DATE_EPOCH` for reproducible output; tests inject a fixed timestamp.
- Non-fatal preprocessor warnings are reported through `Diagnostics`, not direct
  logging, so tests can assert expected warnings without confusing Zig's test runner.
- No macro hygiene — fully textual expansion like a C preprocessor.

---

## src/lexer.zig

**Design:** Hand-written single-pass lexer. Produces a `Token` stream with
`Span` (byte offset + length) for error messages.

**Key decisions:**
- All IDL4 keywords are reserved (e.g. `module`, `struct`, `sequence`, `bitset`,
  `bitmask`, `annotation`, `int8`, `uint16`, etc.).
- `@` is lexed as its own token (`ANNOTATION`), not part of the annotation name.
- Octal/hex/float literals all handled; wide character (`L'x'`) and wide string
  (`L"…"`) literals represented as separate token kinds.
- Span offsets are relative to the expanded (post-preprocessor) source, not the
  original file. Error messages include the pre-expansion source file name
  passed down via preprocessor line markers.

---

## src/ast.zig

**Design:** Tagged union per node kind. No visitor pattern — callers switch on
the tag directly.

**Key decisions:**
- `ArenaAllocator` memory model: all AST nodes live in one arena allocated at
  parse time. When the arena is freed (after IR build), the entire AST goes away.
- Annotation applications (`AppliedAnnotation`) carry a `params` slice. The
  parser does NOT evaluate annotation param expressions — that happens in the
  IR builder.
- Scoped name references are unresolved strings at the AST level; resolution
  happens in semantic analysis.

---

## src/parser.zig

**Design:** Recursive descent with backtracking on ambiguous alternatives.
One function per grammar rule (`parseModuleDecl`, `parseStructType`, etc.).

**Key decisions:**
- Follows IDL4 Annex A grammar exactly (227 rules). `::+` alternatives are
  collapsed into the primary rule function.
- Parses all IDL4 constructs including value types, component declarations,
  home declarations, and template modules — even those the IR builder drops.
  This ensures parse correctness is tested against the full grammar.
- Annotation application (`@Foo`) is parsed at every `<element>` position
  permitted by §8.2. The parser does not validate annotation applicability.
- Parser error recovery: on unexpected token, parse error is returned immediately
  (no panic-mode recovery). Tests use small self-contained snippets.

---

## src/semantic/

Three files:

### src/semantic/scope.zig
Hierarchical symbol table. `Scope` structs form a chain. Names are resolved by
walking the chain outward. Qualified names (`Foo::Bar`) are resolved component
by component.

### src/semantic/const_eval.zig
Constant expression evaluator. Handles integer/float arithmetic, bitwise ops,
string concatenation, enum value resolution, and `sizeof`. Result type: `ConstValue`
(tagged union of integer | float | string | boolean | character | wide variants).

### src/semantic/analyzer.zig
Two-pass:
1. Forward pass: collect all type names and forward declarations into scope.
2. Full pass: resolve all type references, validate types, evaluate const exprs.

**Key decisions:**
- Forward declarations are tracked; only the full definition is emitted in the IR.
- Duplicate definitions are an error; re-opened modules are allowed (IDL4 §7.5.2).
- No type-checking of const assignments (e.g. `const long x = "hello"` is not
  caught — see Known Limitations in [`implementation_status.md`](implementation_status.md)).

---

## src/ir/

### src/ir/types.zig
All IR data types. Key properties:
- `TypeRef`: fully resolved reference; no scoped names remain.
- `TypeDecl`: pointer into the arena to a named type node.
- `TypeAnnotations`, `MemberAnnotations`, `EnumAnnotations`: pre-interpreted
  OMG annotation fields. `raw: []const RawAnnotation` carries everything else.
- `Spec`: root; owns the arena. `spec.deinit()` frees everything.

### src/ir/builder.zig
Builds the IR from (AST, Analyzer) in two passes:
1. First pass: allocate all named type nodes, populate the type map.
2. Second pass: fill in all fields, resolving type references.

**Key decisions:**
- Module re-opening is merged: each module appears exactly once in the IR.
- Annotation interpretation: `interpretTypeAnnotations`, `interpretMemberAnnotations`,
  `interpretEnumAnnotations` are the three pre-interpretation functions.
  See [`idl4_annotations.md`](idl4_annotations.md) for the full list of what is
  pre-interpreted vs raw.
- Advanced constructs (value_dcl, component_dcl, home_dcl, template modules) are
  parsed and dropped here with a warning diagnostic to stderr.
- `@topic` (not an OMG standard annotation, but a common DDS extension)
  is pre-interpreted into `TypeAnnotations.is_topic`.

---

## src/backend/interface.zig

Defines the vtable contract all backends implement. See [`backend_interface.md`](backend_interface.md).

- `Backend.Vtable`: `language_id`, `generate`, `deinit`.
- `Options`: all CLI flags passed through to every backend.
- `Profile`: `.full` (default) or `.xrce`.
- `validateXrce`: called before backends when `--profile xrce` is set.
- `cNameFromQualified`, `prefixedCNameFromQualified`: shared name utilities.

---

## Key Invariants

**Memory ownership**: The `ArenaAllocator` is allocated at parse time and lives
until `spec.deinit()` is called after code generation. AST nodes, IR nodes, and all
string data share this arena. Backends must not hold pointers into the arena after
`deinit`.

**Annotation flow**: Annotations are unresolved strings in the AST
(`AppliedAnnotation.params`), evaluated by the IR builder
(`interpretTypeAnnotations` / `interpretMemberAnnotations` / `interpretEnumAnnotations`),
and delivered to backends as pre-interpreted fields in `TypeAnnotations` /
`MemberAnnotations` / `EnumAnnotations` plus a `raw` slice for unknown annotations.
Backends never call `const_eval` directly.

**Scoped name resolution**: All scoped names (`Foo::Bar`, `::Baz`) are resolved to
`TypeDecl` pointers in the IR builder. No unresolved name strings exist at the IR
level or below.

**Module merging**: Re-opened IDL modules are merged by the IR builder. The IR
contains each module exactly once regardless of how many times it was opened in the
source.

**XRCE validation**: `validateXrce` runs before backends when `--profile xrce` is set,
rejecting unbounded sequences, mutable/appendable extensibility, and map types.
Backends can assume these constraints hold and do not re-validate.
