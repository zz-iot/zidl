# Strict generated authoring records

`--zig-generate-authoring` is an opt-in Zig generator feature. It emits static
`toml_fields`/`tomlSpec` schema metadata and a `decodeToml` entry point backed by
`zidl_rt.authoring`. It is independent of the legacy mutating `applyToml` API:
existing `--zig-generate-toml-config` output and dependency behavior are preserved.
The new flag adds methods/metadata, not data fields or an application configuration
format. Pair the generated code with the matching runtime release.

For configuration-only records:

```sh
zidl -b zig --single-file --zig-generate-authoring \
  --no-typesupport --no-typeobject-support -o generated config.idl
```

Application/sample IDL and any execution-plan wire schema are separate concerns.
This mechanism contains no DDS, experiment, deployment or process semantics.

## Tree contract

The decoder accepts a duck-typed table with `entries.keys()/count()`, `get(name)`
and a `location`. `get` returns an optional node with `value` and `location`.
Locations contain byte offset, line and byte column. Node values expose tagged
`table`, `array` (nodes), `string`, `integer`, `float`, and `boolean` alternatives.
Nested tables satisfy the same contract; the parser remains owned by its consumer.
The independent integration tests construct trees directly without a parser.

```zig
var diagnostic: zidl_rt.authoring.Diagnostic = .{};
var result = try Config.decodeToml(allocator, table, .{}, &diagnostic);
defer result.deinit();
if (result.isPresent(&.{ "settings", "enabled" })) {
    // Explicit false remains different from omission.
}
```

The returned owner owns its value's strings/collections and copied presence/source
paths in one arena. The source tree can be destroyed after decoding. Do not copy
that owner, mutate its arena-backed value or call generated field-level `deinit`
on the value. Release the returned owner once. Any failure releases its complete
arena and leaves the source tree and prior decoded results untouched.

IDL defaults remain visible in the value for inspection; callers must consult
presence before inheritance/overlays. They are not automatically resolved settings.
Presence distinguishes omitted fields from explicit zero, false, empty strings and
empty sequences. Source paths retain separate segments and collection kinds, rather
than encoding identity into dotted strings. `source(path)` retrieves locations;
`collectionIsNamed(path)` distinguishes named collections from positional arrays.

Diagnostics contain an error, source location and a fixed 512-byte display path
with an explicit truncation flag. That storage survives failed-allocation rollback.
OOM propagates as OOM; it does not pretend to be a schema validation failure.
File names are supplied/retained by the consuming frontend, not inferred by this
schema-independent decoder.

## Supported subset

- Optional and ordinary scalar fields, checked integer ranges and finite floats.
- Unbounded/bounded strings; embedded NUL is rejected consistently, including
  C-string elements of generated sequence buffers.
- Canonical case-sensitive IDL enum names mapped to their declared numeric values,
  independently of native tag spelling or the legacy case-insensitive helper.
  Numeric mapping follows the enum currently emitted by zidl; this feature does
  not expand frontend support for enum annotations.
- Nested records, fixed arrays with exact length, bounded/unbounded sequences,
  nested sequences and scalar/record sequence elements.
- Explicit named-record convention: pass `.named_field = "name"` to decode a table
  as a record sequence, injecting each table key into that string member. Unknown
  members and a simultaneously supplied name field are rejected. No convention is
  enabled by default.

IDL inheritance, unions, wide strings, opaque types and unsupported representations
return `UnsupportedType` rather than dropping fields. Generated declarations
`toml_fields`, `tomlSpec` and `decodeToml` are reserved when this flag is enabled;
collisions fail generation. Empty records are supported on the configuration-only
path above. This does not qualify every combination of wire-generation flags.

Default limits are depth 64, 65,536 decoding work units, 4 KiB per string and 4 MiB
of copied presence-path text. IDL string/sequence bounds are checked separately.
The consumer supplies syntax/resource limits and any DDS-specific validation;
none of these checks establishes a complete TOML implementation or DDS conformance.

`zig build test-authoring` compiles/runs generated fixtures for presence, bounds,
named records, nested sequences, diagnostics, allocation failures and empty records.
The target also joins ordinary tests and emitted coverage artifacts. The consumer
integration in zzdds uses its existing generic TOML parser, not a second decoder.

## Conditional settings and compatibility choices

Pass `.conditional_members = true` to interpret `_setting` at schema-member
positions as “apply `setting` if the schema contains it, otherwise skip it.” Known
settings still receive normal validation. An unknown conditional section is skipped
as a whole; a recognized section still rejects ordinary nested typos. The syntax
parser must validate the whole document first. Named collection keys, such as a
profile called `_Telemetry`, remain literal names.

`setting` together with `_setting` is a duplicate in either order. `_` and names
starting with `__` are invalid member spellings under this convention, and schemas
with public leading-underscore members are rejected. With the convention disabled,
underscores have no special meaning.

The result records canonical applied paths separately from `input_path` spellings.
Skipped settings appear only in `skipped`, with paths, source locations and a reason:
`conditional_unknown` or `compatibility_unknown`. Neither reason proves that a
particular runtime feature is absent. Known runtime capability failures are not
suppressed. `max_skipped` bounds the report; exhaustion fails with `LimitExceeded`.
Setting `capture_skipped = false` retains the count and marks `skipped_complete`
false when anything was skipped. No global logging is performed.

The default rejects ordinary unknown members and accepts canonical enum names.
Consumers preserving older configuration policies may explicitly choose
`.unknown_fields = .ignore` and `.enum_matching = .ascii_case_insensitive`.
Setting `capture_element_presence = false` retains collection-field presence while
omitting individual element histories, useful for large configuration string lists.

## Read using an existing value

```zig
var replacement = try Config.decodeTomlFrom(allocator, current, table, .{}, &diagnostic);
defer replacement.deinit();
```

Omitted fields retain their existing values, including nested records. Explicit
false, zero and empty strings replace them. A supplied sequence replaces the whole
sequence; `[]` clears it. Omitted sequences are independently copied. An existing
optional record retains unspecified children; a newly supplied optional record starts
from IDL defaults. TOML has no null/reset literal here.

The starting value is borrowed only during the call. The replacement owns its own
storage, and failures leave the starting value untouched. Presence describes this
input, not historical edits. This operation does not merge profiles or install
process state. `decodeTomlFrom` is also a reserved generated declaration when the
new flag is enabled. Legacy `applyToml` remains available and unchanged.
