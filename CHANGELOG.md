# Changelog

Notable changes to zidl, newest first. For current capability and known limitations see
[`docs/implementation_status.md`](docs/implementation_status.md); for planned work see
[`docs/roadmap.md`](docs/roadmap.md); for design rationale see
[`docs/decisions.md`](docs/decisions.md).

Versions are the `vX.Y.Z-zig.0.16.0` release tags.

## v0.3.12-zig.0.16.0 — 2026-08-30

- **Fixed `get_key_value` returning the wrong key for types whose `@key` member is not
  first.** zzdds stores the whole last-alive sample keyed by instance handle
  (`key_registry` on the writer, `key_cdr` on the reader), not a key-only blob, but every
  backend's generated `get_key_value` parsed it with the *key-only* deserializer
  (`deserializeKeyInto` / `{Type}_deserialize_key` / `deserializeKey`), which expects a
  stream that starts at the key member. For `struct M { string label; @key long id; }` it
  read `label`'s length prefix as `id`; it only worked when the key was the leading
  member. Found by zzdds's stress-suite `instance` scenario. Key-only helpers are
  unchanged (still used for disposed/unregistered samples on the take path).
  The fix is a **selective-parse family**, emitted per Topic struct under
  `--generate-zzdds-wrappers`: a `FieldMask` (`u64`, member index → bit),
  `KEY_FIELD_MASK`, a `name → index` lookup, `deserialize_selected(reader, want, out
  [, alloc])` — walks members in declaration order, decoding the ones whose bit is set in
  `want` and **skipping** (not decoding) the rest — and `deinit_selected(out, want
  [, alloc])`, which frees exactly the wanted heap members. `get_key_value` drives it with
  `KEY_FIELD_MASK`, so a large non-key member (a blob, a long string) is stepped over, not
  allocated and copied. Fallback to the full deserializer for a struct with a base type or
  > 64 members.
- **`get_field_from_cdr` now skip-parses too** (all four backends). ContentFilteredTopic /
  QueryCondition evaluation resolves the referenced field name to its member index and
  calls `deserialize_selected(1 << idx)` instead of a full `deserialize` — so a filter
  like `count > 5` on a type with a 100 KB non-key member no longer decodes (and, in
  C/C++, allocates + frees) that member on every sample. Previously each `get_field`
  call did a full decode; a multi-field filter (`a > 5 AND b < 10`) did one per reference.
  - **Zig**: `deserializeSelected` / `deinitSelected` / `KEY_FIELD_MASK` / `fieldIndex`.
    Runtime test: `test/integration/zig_wrapper_contract` "deserializeSelected …".
  - **C**: `{Type}_deserialize_selected` / `{Type}_deinit_selected` / `{TYPE}_KEY_FIELD_MASK`
    / `{Type}_field_index`.
  - **C++**: `{Type}_deserialize_selected` / `{TYPE}_KEY_FIELD_MASK` / `{Type}_field_index`
    — no `_deinit_selected` (the `::Foo` members are RAII, so a mid-parse error and normal
    teardown are both handled by `key_out` going out of scope).
  - **Java**: `{Type}.deserializeSelected(buf, cdrBase, xcdrVersion, want)` /
    `{Type}.KEY_FIELD_MASK` / `{Type}.fieldIndex(name)` — no `deinitSelected` (GC).
  - C/C++ compile-verified against the real zzdds headers; Java compile-verified
    (golden compiled by `integration-test`) and runtime-verified
    (`test/integration/java/Test.java` "testSampleDeserializeSelected").
- **`skipPrimitives(count, elem_wire_size)`** — `CdrReader.skipPrimitives` (zidl-rt) and
  `zidl_cdr_skip_primitives` (zidl-cdr) — plus a `skip()` fast path: a
  `sequence<primitive>` / primitive array is stepped over with one aligned cursor advance
  instead of a per-element read-and-discard loop. The C and C++ backends' near-verbatim
  skip codegen is now a single shared module, `src/backend/cdr_skip.zig` (skip is
  representation-agnostic — it never touches the output struct).
  - `count == 0` short-circuits before the element-alignment step: an empty sequence
    emits only its length prefix (no elements → no leading alignment padding), so
    aligning would consume bytes belonging to the next member. Manifested in XCDR1 where
    element alignment (up to 8) exceeds the 4-aligned post-length cursor. (greptile PR #47)
  - The C helper rejects a `count` whose `count * elem_wire_size` would wrap `size_t` on
    a 32-bit target rather than skipping a truncated body past the bounds check. The Zig
    helper already checked this (`std.math.mul`).
  - `zidl_cdr_skip` and `reader_read_slice` now bounds-check as `n > data_len - pos`
    (the subtraction is safe — `pos <= data_len` is invariant) instead of `pos + n >
    data_len`, which wraps for a hostile `n` on a 32-bit target and would move the
    cursor backwards. (greptile PR #47)
  - `reader_align_pos` clamps to `data_len` — a sample truncated inside a member's
    alignment padding could otherwise leave `pos` past the buffer, underflowing the
    `data_len - pos` check above and letting a later read run off the end. (greptile
    PR #47, security)

## v0.3.11-zig.0.16.0 — 2026-08-25

- **User-supplied CDR allocator implemented** (`ZidlAllocator` + `zidl_cdr_set_allocator`,
  `packages/zidl-cdr`). `zidl_cdr_read_string`/`read_wstring`, the C backend's generated
  inline sequence-buffer allocation, and `@default("...")` string handling all route
  through `zidl_cdr_alloc`/`_free`/`_strdup`/`_free_str`/`_free_wstr`, falling back to libc
  when no allocator is registered. Deliberately **process-wide** (one global, set once at
  startup) — see `docs/decisions.md`.
- **`--cpp-pmr-containers`** (C++ backend): opt-in `std::pmr` container generation so
  `std::vector`/`std::string` fields in generated types route through a caller-controlled
  allocator. Source/ABI break, hence opt-in.
- **`{Type}_free()` bodies** for the C backend completed, including two previously-silent
  gaps: string-only structs and bounded-sequence-only structs had no `_free()` declared at
  all.
- Fixed four C++ backend bugs surfaced only by a real compile+link+run of zzdds's own
  `zzdds_impl.cpp` (not `dcps_impl.cpp`): cross-module `native_handle()` override mismatch
  (import-fill was clearing real `.bases`); listener trampoline resolving a cross-module
  `@callback` entity parameter's class in the wrong namespace; an `_getOrCreate` regression
  compiling `make_shared` bodies for intentionally-abstract entity classes; scalar-typedef
  listener parameters passed by pointer where the C listener struct declared them by value.

## v0.3.10-zig.0.16.0 — 2026-08-25

- Fixed float32 content-filter metadata generation.

## v0.3.9-zig.0.16.0 — 2026-08-24

- Fixed a `key_hashes` allocator mismatch in the raw-op typed wrappers.

## v0.3.8-zig.0.16.0 — 2026-08-23

- **Raw / loaned DataReader & DataWriter codegen**, all four backends. Replaces the old
  hand-written, C/C++-only `zzdds_*_raw` family with real `dcps.idl` operations
  (`take_raw`, `read_raw`, `take_next_instance_raw`, `read_next_instance_raw`,
  `return_loan_raw` on `DataReader`; `write_raw`, `loan_raw`, `publish_loan_raw`,
  `return_loan_raw` on `DataWriter`), generated the same way every other reader/writer op
  is. `max_len == 0` signals loan-vs-copy, inferred from parameter shape (no new
  annotation); this retroactively fixed the `_w_condition`/`take_next_instance` family's
  spec compliance too. Design: `zzdds/docs/design/raw-loan-api.md`.
- `zidl-cdr` gained a third `ZidlCdrWriter` mode (`zidl_cdr_writer_init_counting`) for
  client-side write-loan sizing; wired into the C/C++ backends' generated
  `write`/`dispose`/`unregister`.
- Java write-loan buffers land as a `java.zig` codegen special case
  (`isWriteLoanBufferOp`) producing a real `java.nio.ByteBuffer`-backed
  `loan_raw`/`publish_loan_raw`/`return_loan_raw`, preserving buffer identity across the
  JNI boundary (the generic per-op marshaling copied through a fresh buffer per call,
  losing identity — confirmed to publish uninitialised memory before the fix).
- Fixed a real gap: C and C++'s typed reader family carried a 3-field `zzdds_sample_info`
  instead of the 12-field spec `SampleInfo`; Java's `Sample` had the same gap. Only Zig was
  correct before.

## v0.3.7-zig.0.16.0 — 2026-08-20

- Fixed the Java JNI `@optional` scalar marshaling path, which crashed the JVM
  (`zzdds_UdpConfig.deinit` dereferencing garbage) — a real C-ABI struct-layout mismatch,
  fixed via zidl's C-ABI mirror mechanism (`@optional` scalars only; string / nested-struct
  / sequence optional members still need the same treatment — see roadmap Known Gaps).
- Fixed `javaFieldDescriptor` (`descriptor()`) generation, found in the same generator.

## v0.3.6-zig.0.16.0 — 2026-08-18

- Fixed a Zig `getFieldFromCdr` unused-parameter bug.
- Exposed `instance_state` on Java's batch-take `Sample` family (was an
  `UNKNOWN_INSTANCE_STATE` -1 sentinel).

## v0.3.5-zig.0.16.0 — 2026-08-13

- **C-ABI entity identity unified across bindings.** A C-ABI handle is the address of a
  heap `EntityBox{ptr, vtable}` with no type tag; each interface *view* of one object was
  boxed to its own address, so an application could not recognise a `GuardCondition` it
  attached to a `WaitSet` in `wait()`'s base-`Condition` result by handle/wrapper identity.
  Fixed at the root with a new `@shared_c_abi_box` IDL annotation and a nested
  `CAbiViews`/`unboxAsView` box representation (opt-in per interface): every primary-base
  ancestor view of an object now shares one cached box. Propagated to C++ (shared-family
  `_getOrCreate` — one cache per box-identity family, not per concrete class) and Java (a
  native weak-global-ref box cache — Java had no wrapper-identity cache at all before).
  Design: `docs/design/binding-c-abi-identity.md`.
- **ContentFilteredTopic filtering wired for every backend** via `get_field_from_cdr` —
  previously no backend emitted zzdds's `TypeSupport.get_field` hook, so CFT filtering
  silently never activated in any binding. Needed a Java bare-`sequence<T>`-param JNI
  marshaling fix along the way.
- **Java backend: real entity JNI bridge, QoS/status struct marshaling, listener JNI
  upcall trampolines, `--generate-zzdds-wrappers` support.** Previously `dcps_jni.c` never
  linked (wrong symbol names, structs/listeners by value, naive `jobject`↔handle casts) and
  was never compiled or run. Also fixed a `jstring` handling bug (`string`/`wstring` params
  and returns cast directly to `const char *` instead of going through
  `GetStringUTFChars`/`NewStringUTF`) that produced consistent-garbage topic/type names
  within one JVM — invisible in-process, a silent cross-process discovery-match failure.
  Verified with two real JVM processes over UDP RTPS plus a compiled+linked JNI integration
  test in `integration-test`.
- **`--zig-generate-toml-config`** (Zig backend): per-struct `applyToml(alloc, table)`
  driven entirely by the IR. Found and fixed a real pre-existing leak: `clone()` was only
  emitted in the typesupport-enabled path, never under `--no-typesupport`.
- **`--cpp-impl-override` / `--cpp-impl-include`** (C++ backend): lets `--cpp-generate-impl`
  construction and `dynamic_cast` parameter-adaptation sites resolve a vendor-extended
  concrete class instead of the default abstract one. Scoped as a blind mechanism (no
  second-IDL parsing) so a future plugin could emit it.
- **`--c-no-free`** (C backend): suppresses `{Type}_free()` for a whole generation pass, for
  a consumer that already exports `{Type}_free` for the same structs from elsewhere (zzdds
  hit 25 duplicate-symbol link errors compiling its own `dcps_cdr.c` into `libzzdds.so`).
- **`--zig-generate-c-api` bare `sequence<EntityInterface>` params**: entity-sequence
  elements (`DataReaderSeq`, `ConditionSeq`, …) now boxed to the C-ABI single-opaque-pointer
  layout instead of the native 16-byte fat-pointer, fixing binary-layout corruption.
- **Zig backend `computeKeyHashFromCdr` + `deinit()`/`clone()` parity**: generates the
  Zig-backend equivalent of C/C++/Java's `{Type}_compute_key_hash_from_cdr`, and widened
  `deinit()`/`clone()` to cover plain unbounded `string`/`wstring` fields (previously only
  unbounded sequences — a real leak in generated code).
- **C++ backend `dynamic_cast` for entity parameters now tries every sibling implementor**
  (`collectBaseImplementors`), e.g. `TopicDescription` → `Topic`/`ContentFilteredTopic`;
  fixed a bug where `ReadCondition` (both a base and a real interface with its own ops) was
  wrongly excluded from that set.
- Fixed an entity-sequence typedef `_free` stride bug.

## v0.3.0–v0.3.4-zig.0.16.0 — 2026-07-31 … 2026-08-11

- Java backend updates and Java XCDR1/XCDR2 interop fixes (PRs #34, #35).
- Cross-backend C-ABI / JNI bug fixes (#36).
- Added missing implicit typed-DataReader/DataWriter methods across backends: the full
  `read_w_condition`/`take_w_condition`/`*_next_instance_w_condition` family (missing from
  every backend), batch `read_instance`/`take_instance` (C/C++/Java), and Java's
  `get_key_value`/`lookup_instance`/`register_instance`/`*_w_timestamp` family (#37, #38).
  Instance selection respects the condition per spec §2.2.2.5.3.18-19.

## v0.1.x–v0.2.x-zig.0.16.0 — 2026-05 … 2026-07

- Initial IDL4 front end (parser, semantic analysis, IR builder), and the C, C++, Java, and
  Zig backends with inline XCDR1/XCDR2 CDR.
- `--generate-interfaces` (opaque-handle / vtable interface+impl split), `--generate-c-api`
  (Zig C-ABI export wrappers), `--generate-zzdds-wrappers` (typed DataReader/DataWriter),
  `--zig-pl-cdr` (RTPS ParameterList CDR, Zig only), `--profile xrce` + `--zig-version
  0.15.1` (bounded-only XRCE-profile Zig output on `zidl_rt.BoundedArray`).
- TypeObject/TypeIdentifier encoder (Zig backend only).
- Const type-checking and union-discriminant-type validation diagnostics (PR #20).
- Entity-handle heap-boxing on the zidl side; the `as_{Base}` upcast vtable slot; the C
  backend's opaque `typedef struct Foo_s *Foo;` handle representation.
