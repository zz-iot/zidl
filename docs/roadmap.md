# Backend Roadmap

Planned backend work, ordered by dependency and real-world priority.
For what is currently implemented, see [`features.md`](features.md).

---

## Raw / loaned DataReader & DataWriter codegen — implemented (2026-08-22)

Full design lived in `zzdds/docs/design/raw-loan-api.md` (and zzdds's own roadmap entry,
2026-08-22) — recorded here because the actual codegen work spanned all four backends plus
`zidl-cdr`, not just zzdds core. What landed, per highlight below:

- `max_len == 0`-signals-loan branching for generated `take`/`read` (typed and the new raw
  ops) landed, inferred structurally from parameter shape — no new annotation needed.
  Retroactively fixed the existing `_w_condition`/`take_next_instance` family's spec
  compliance too.
- New raw ops (`take_raw`, `read_raw`, `take_next_instance_raw`, `read_next_instance_raw`,
  `return_loan_raw` on `DataReader`; `write_raw`, `loan_raw`, `publish_loan_raw`,
  `return_loan_raw` on `DataWriter`) landed as real `dcps.idl` operations, generated the
  same way every other `DataReader`/`DataWriter` op is — not a hand-written per-binding
  extension. Broader than the design doc's illustrative sketch (which only showed
  `take_raw`'s unfiltered shape): `read_raw` and the `_next_instance` pair were added for
  full parity with the old hand-written raw family's instance/condition-filtered variants,
  and `write_raw` gained a `source_timestamp` parameter to cover the `_w_timestamp` family.
- `zidl-cdr` got a third `ZidlCdrWriter` mode (`zidl_cdr_writer_init_counting` — `buf ==
  NULL`, just advances `len`/`pos`) alongside the existing dynamic/fixed modes, for
  client-side write-loan sizing — wired into the C and C++ backends' generated
  non-timestamped `write`/`dispose`/`unregister` (count via the counting mode, then
  `loan_raw` a buffer of exactly that size, then serialize into it via the existing fixed
  mode). Not wired into Java: Java's generated serialization already produces an
  exactly-sized `byte[]` via its own grow-and-retry `BufferOverflowException` loop, so the
  Java typed wrapper reuses that length directly rather than needing a counting mode of its
  own.
- Java's write-loan buffer exposure did **not** end up as a new hand-written method in
  zzdds's `zzdds_java_runtime.c`, contrary to what this entry originally predicted — it
  landed as a `java.zig` codegen special case instead (`isWriteLoanBufferOp` in
  `src/backend/java.zig`), generating a real `java.nio.ByteBuffer`-backed
  `loan_raw`/`publish_loan_raw`/`return_loan_raw` for the base `DataWriter` interface
  through `NewDirectByteBuffer`/`GetDirectBufferAddress`. `zzdds_java_runtime.c` needed no
  changes. This surfaced a real, previously unexercised bug in the *generic* per-op JNI
  marshaling these ops would otherwise have used: it copies through a fresh native buffer
  on every JNI call boundary, losing the loaned buffer's identity between `loan_raw()` and
  `publish_loan_raw()` — confirmed via a real re-break that published uninitialized memory
  as sample data, not merely a resource leak. Fixed by special-casing these three ops
  (interface, impl, and JNI-bridge emission) to preserve identity via `ByteBuffer` instead
  of the generic `List<Byte>` copy-both-ways marshaling every other `OctetSeq` param uses.
- Also fixed a real, live bug found along the way: C and C++'s entire typed reader family
  carried an incomplete 3-field `zzdds_sample_info` instead of the real 12-field spec
  `SampleInfo` (missing `source_timestamp` and every generation/rank field) — Java's
  `Sample` class had the same gap inlined; only Zig was correct before this landed.

---

## Plugin architecture — direction, not yet started

**Not scheduled; recorded here so near-term flag additions don't quietly paint zidl into
a corner.** zidl currently has a small but growing set of flags whose only real reason to
exist is "what zzdds specifically needs from its C++/Java/etc. impl generation"
(`--cpp-generate-impl`'s override mechanism below is the newest example; the C ABI's
`--generate-zzdds-wrappers` is an older one, named after zzdds outright). Every one of
these bakes a specific DDS implementation's opinions into zidl core, permanently, even
though zidl's stated audience is "any DDS implementation, or none" (see the Python/C#/
Rust backend sections below — none of them are zzdds-specific).

The direction being pointed at, not committed to a design yet: pull the
implementation-specific pieces of each backend (which concrete class backs an abstract
IDL interface, wrapper-generation conventions, listener-bridging conventions, ...) out of
zidl core and into a set of implementation-owned plugins — in zzdds's case, one plugin
per binding it ships (Zig/C/C++/Java), living in the zzdds repo, not this one. zidl core
would stay responsible for the IDL-to-IR pipeline and the generic per-language emission
primitives (type mapping, CDR codegen, the interface/impl split); a plugin would supply
the policy layer on top (e.g. "construct `zzdds::DataWriterImpl`, not the interface's
default impl, for `DataWriter`").

Until that split exists, new implementation-specific needs should still land as explicit,
mechanism-only flags (blind substitution/config zidl doesn't validate against another
IDL file) rather than teaching zidl core to parse a second IDL file and infer policy from
it — the latter is exactly the kind of decision a future plugin should own, and building
it into core now would likely need to be unwound later. `--cpp-impl-override`/
`--cpp-impl-include` (below) are being scoped with this in mind: primitive enough that a
future plugin could emit them programmatically instead of a human hand-writing them into
`build.zig`.

---

## Binding design review: interfaces vs. impls, inheritance, and C-ABI identity — review complete, decision recorded below

**Review complete (2026-08-12) — see "Binding design review: decision" below for what was decided. This section is kept as the historical record of the prep work the decision was based on; recorded here originally so the tensions found while building the WaitSet/condition
example (`zzdds-examples/{zig,c,cpp,java}/waitset/`, see `zzdds/docs/roadmap.md`'s matching
entry) don't get lost before a deliberate review happens.** The ask: a general review of
zidl's overall pattern for generated classes/interfaces/listeners vs. their concrete impls
— especially interface inheritance and C-ABI boxing/unboxing — aiming for one strategy that
feels consistent across bindings and stays as flexible as possible without giving up much
performance. This section records the concrete tension that prompted the request, plus
other complications noticed along the way, as review scope — not a design, and not a
decision about what changes.

**The anchor case: condition identity survives "same view, asked for repeatedly" but not
"same object, different view."** Two existing mechanisms already give wrapper/handle
identity, and it's worth being precise about the guarantee each one actually makes:

- `CachedCAbiHandle` (`zzdds/src/util/c_abi_handle.zig`) gives a Zig object one C-ABI box
  *per interface view*, lazily created and reused for the life of the object (replacing two
  earlier designs — a hybrid leaf/base split that mis-dispatched on nil results, and
  box-fresh-every-call, which broke identity and leaked on widened-view accessors). A
  `TopicImpl` asked for its `Topic` box twice gets the same box both times. Asked for its
  `Entity` box, it gets a *different*, independently cached box — correctly, since each
  view needs its own vtable.
- `_getOrCreate` (C++ backend, `ConcreteImplGenerator`) gives the C++ wrapper the same
  guarantee one level up: a per-class `handle -> weak_ptr<Impl>` cache means the same C-ABI
  handle in always yields the same `shared_ptr` out, at every entity-returning call site
  (op return, attribute getter, sequence-of-entities out-adaptation, listener-trampoline
  argument).

Both mechanisms were built to solve the same narrower problem: repeated requests for *the
same interface view* of the same object must yield the same wrapper. Neither was ever asked
to solve, and neither does solve, "is this the same underlying object as that other view I
already hold." `GuardConditionImpl` boxes as `GuardCondition` via one cached field and as
`Condition` via a second, independently-cached field — two different, unrelated-looking
boxes for one Zig object, by design. This is invisible until an API genuinely needs
cross-view identity, and `WaitSet.wait()` is the first place that happened: it always
returns conditions boxed as base `Condition` (via `_getOrCreate`'s handle-keyed cache,
keyed on the `Condition`-view handle), so an application holding a `GuardCondition` it
attached earlier cannot recognize it in `wait()`'s result by pointer/handle/wrapper-identity
comparison — only by re-deriving identity out-of-band (in this case, checking each held
condition's own `get_trigger_value()` directly instead of trusting list membership). Worked
around at the application layer in all four `waitset` example ports; not fixed at the root.
See `zzdds/docs/roadmap.md` for the fuller bug writeup.

**A related, but distinct, asymmetry: parameter adaptation tries harder than return
adaptation.** `collectBaseImplementors` (`zidl/src/backend/interface.zig`) builds a
dynamic_cast cascade so an entity/condition *parameter* (e.g. `attach_condition(Condition)`)
can be recovered as its real concrete type by trying each candidate subclass in turn. There
is no equivalent cascade for entity/condition *return values* — a return is boxed once, as
whatever view the operation's IDL signature declares, and never tries to recover a more
specific concrete type the way a parameter does. This asymmetry is the deeper mechanical
root of the `wait()` bug above (it's a return-value site), but it's worth naming as its own
axis, separate from the caching tension, since a review might fix one without the other.

**What the current design gets right — worth preserving, not just working around:**
- C's opaque-handle-per-interface model sidesteps wrapper-identity entirely: the handle
  *is* the identity, there's no wrapper object to keep in sync with it. Simpler, and
  arguably the reason C hasn't hit this bug — worth understanding *why* before assuming
  C++/Java's richer wrapper model is strictly better.
- C++'s real inheritance (`Condition`/`GuardCondition`/etc. as genuine C++ subclasses) makes
  upcasting free and implicit — no manual `as_Condition()` call needed, unlike Zig's
  interface-as-vtable model (see next point). Confirmed a real ergonomic win this round.
- Zig's native `{ptr, vtable}` fat-pointer representation needs no boxing at all for
  pure-Zig-to-Zig code — identity is exact, free, and this whole class of bug structurally
  cannot occur there. The bug only exists at the C-ABI boundary and above.
- The synthetic `as_{Base}` upcast method zidl generates is uniform and mechanical — no
  hand-maintained per-consumer mapping of "which interfaces can this one be viewed as."
  Noticed one inconsistency worth a follow-up, not a redesign: pure Zig-native code doesn't
  get an `as_{Base}` convenience method the way C/C++/Java do (their vtable slot exists, but
  there's no ergonomic wrapper) — every *other* binding has this ergonomic layer, Zig itself
  doesn't, which stood out while writing `zig/waitset` directly against the native API.

**Other complications noticed, not yet fully explored:**
- **Factory-less entities need hand-written, per-binding bootstrap, three times over, with
  no generated or systematic support.** `WaitSet`/`GuardCondition` have no factory operation
  in `dcps.idl` (per OMG spec, they're app-instantiated directly), so this round needed a
  hand-written C-ABI constructor (`zzdds_create_waitset`/`zzdds_create_guardcondition`), a
  hand-written C++ friend-factory wrapper, and a hand-written Java JNI native method — each
  authored from scratch by mirroring `DomainParticipantFactory`'s existing
  `zzdds_create_factory()` bootstrap by hand, not generated. Every future factory-less
  interface repeats this exact three-times-by-hand cost. Worth asking during the review
  whether zidl could detect "no factory operation, not itself a base interface" and offer to
  generate the bootstrap the way it already generates `as_{Base}`.
- **Listener trampolines may have a latent version of the same cross-view identity gap.**
  Per `docs/decisions.md`'s listener-release-hook design, listener-delivered entity/condition
  arguments already go through `_getOrCreate`-style wrapping in C++ trampolines. That means
  *if* any listener ever delivers a condition or entity through a narrower or different view
  than the application originally held it as, the same "different box, same object"
  confusion is possible there too — not confirmed to have happened, not investigated this
  round, but structurally the same mechanism, so worth checking deliberately rather than
  assuming listeners are exempt because conditions were the first place it surfaced.
- **The un-swept box cache's memory tradeoff may not generalize to every workload.**
  `CachedCAbiHandle` and `_getOrCreate` both accept "boxes/wrapper entries live as long as
  the owning object, no active cache-sweep" as fine — reasonable for long-lived entities
  like `Topic`/`Writer`, less obviously fine if a review broadens scope to workloads that
  create/destroy many short-lived `GuardCondition`s or `ReadCondition`s rapidly. Worth
  re-confirming under that lens rather than assuming the existing tradeoff generalizes.
  **Closed, not pursuing — see "Other open items — decided" below for the full reasoning.**
- **Allocator tiering is a precedent any redesign needs to keep, not incidentally break.**
  Boxes/wrappers are allocated through the existing allocator-injection machinery (the
  Tier 0-3 allocator-strategy work); a redesign of the boxing/caching layer should keep
  taking an allocator as a parameter rather than reintroducing a hardcoded one.
- **Fixes here tend to land behind an unreleased zidl checkout, which is its own process
  complication.** Several of this round's real fixes (the `collectBaseImplementors`
  exclusion bug, the entity-sequence `_free` stride bug) only existed as uncommitted local
  changes for a while, consumed by zzdds via a temporary `.path` override in
  `build.zig.zon` rather than a tagged release. Easy to lose track of which zzdds/
  zzdds-examples behavior depends on which specific local zidl state. Not really an
  interface/inheritance/boxing question, but it directly affects how verifiable any future
  review's own findings are, so worth naming.

**Pre-review spike (2026-08-12): `zzdds-examples/spikes/python/` (relocated 2026-08-13, was
`zzdds-examples/python/spike/`) — does the current C/C++/Java
binding set actually cover future-binding usage patterns, before committing this review's
scope?** Prompted by a direct question about whether C#/Python/Rust/Go/Haskell (all sketched
elsewhere in this roadmap, see their own sections below) would surface anything genuinely new
versus what C/C++/Java already exercised. Two candidate gaps were identified by inspection —
foreign-thread-calls-into-a-GC'd-host callback delivery (Python's GIL vs. JNI's
`AttachCurrentThreadAsDaemon`), and `ctx`-pointer lifetime across the C-ABI boundary (the
Go `cgo.Handle` problem) — and a minimal, throwaway `ctypes`-based probe (no zidl Python
backend, no CDR codegen, reuses zzdds's plain C-ABI directly) was built to test them for real
rather than reason about them. Full writeup in the spike's own `README.md`; summary:

- **GIL-attach itself works cleanly, confirmed rather than assumed.** `ctypes.CFUNCTYPE`'s
  automatic `PyGILState_Ensure`/`Release` correctly bootstraps Python thread state for a
  zzdds-internal thread it's never seen (the per-participant DEADLINE/LIVELINESS timer
  thread, chosen as the cheapest "unprompted native callback" trigger), with no leak across
  either many repeated calls from one native thread or many distinct native threads each
  calling in once (60 distinct OS threads stress-tested via repeated participant
  create/destroy, standing in for real writer-heartbeat-thread respawn — see the spike's own
  `probe2` docstring for why that substitution was made and what literal heartbeat-thread
  coverage would additionally need).
- **Real finding, not a zzdds/zidl bug today but a binding-author hazard with no current
  guardrail: dropping a listener's callback objects before the DDS entity is destroyed
  segfaults, reliably.** `create_datareader()` copies a `DDS_DataReaderListener` struct's
  function-pointer *values* into zzdds's internal storage; the ctypes `Structure` instance
  passed in is genuinely dead weight the moment the call returns, but the underlying
  `CFUNCTYPE` *callable objects* must stay alive independently, since ctypes owns the actual
  executable trampoline memory those addresses point at and frees it once nothing references
  the callable. `release_listener_data` (the existing hook `ListenerBox`/`EntityQuiesce`
  fire correctly, per zzdds's own roadmap) is purely advisory here — it tells a binding when
  it's *allowed* to release, it cannot force the binding to have kept holding on until then.
  Confirmed via a deliberately adversarial probe (`probe3_dangling_trampoline.py --unsafe`)
  that drops every Python reference to the callback objects immediately after
  `create_datareader()` returns, then churns the heap to encourage the freed trampoline
  memory to actually get reused before waiting for a callback tick — crashed 3/3 runs, with
  two different fault types across runs (`SIGSEGV` once, `SIGTRAP` once), consistent with a
  genuine jump into freed-and-reused memory rather than one deterministic address. This is
  structurally different from what `ListenerBox`/`EntityQuiesce` protect (the DDS *entity*'s
  zzdds-side lifetime) — the trampoline's backing memory is Python/ctypes-side state zzdds's
  C code has no visibility into at all, so no existing mechanism generalizes to cover it.
  Worth the review deciding whether this stays a documented binding-author contract, or
  whether zidl should generate a small keep-alive registry for callback objects specifically
  (same shape as a `cgo.Handle`-style table, applied to callbacks instead of arbitrary `ctx`
  data) so a real Python (and, by the same argument, C#/Go) backend doesn't have to get this
  right by hand every time.
- **Design refinement on the above, from a follow-up question — the keep-alive registry
  must be keyed per-registration, not per-listener-identity.** A dict keyed by
  `id(python_listener_object)` breaks the ordinary case of one listener object registered
  on multiple `DataReader`s: releasing the *first* reader's registration would pop the
  *only* registry entry, dropping the keep-alive for a listener the *second* reader still
  needs — a self-inflicted version of the same crash. Fix: a fresh trampoline set and a
  fresh registry slot per `create_datareader`/`set_listener` call, even when the same
  Python object is passed twice; ordinary Python refcounting then handles "the same
  underlying object needed by two independent slots" for free. Confirmed this matches
  zzdds's own contract, not just a defensive Python-side choice: `src/dcps/writer.zig`
  copies every entity's listener **by value** into its own `listener_ex_box` — there is no
  notion of shared listener identity across entities at the C-ABI level either.
- **Second design refinement — `zzdds::DataWriterListenerEx` extending
  `DDS::DataWriterListener` does NOT introduce a second "per-view" keep-alive to track,**
  despite the surface resemblance to the `CachedCAbiHandle`/`_getOrCreate` "one box per
  interface view" tension documented earlier in this section. Traced in `writer.zig`: there
  is exactly one storage slot per writer (`listener_ex_box`), always holding the *wider*
  `Ex` shape internally; setting the base listener via `set_listener` widens it
  (`listenerExFromBase`) into that same slot rather than creating a second one, and
  `get_listener()` narrows back down for reads. Widening/narrowing are pure struct-reshapes
  of pointer values the caller already supplied, not a second box or a second release hook
  — one acquire, one `release_listener_data` firing per registration, regardless of which
  interface width the app used. The "one box per view" pattern genuinely doesn't apply here
  at all: that machinery is for *outbound* entity handles zzdds hands back to the app;
  listeners are the opposite direction (the app hands function pointers to zzdds), never
  boxed or cached by identity in the first place.
- **A second, structurally different finding from the same follow-up conversation:
  `WaitSet` attachment is never ownership, and — unlike the listener case — there is no
  existing hook a binding could use to know when it's safe to release its own keep-alive
  for an attached condition.** Per DDS 1.4, a `WaitSet` never owns what's attached to it;
  real ownership is automatic (tied to the parent `Entity` for `StatusCondition`), tied to
  the parent `DataReader` (`ReadCondition`/`QueryCondition`, explicit `delete_readcondition()`
  or implicit at reader teardown), or — the sharp case — tied to the *application itself*
  for `GuardCondition`, which has no owning factory at all. zzdds's own condition/`WaitSet`
  lifecycle fix (see zzdds's roadmap "WaitSet / condition example") already guarantees the
  memory-safety half is handled — destroy a condition's true owner while still attached,
  with no explicit `detach_condition()` first, and `WakeupList.invalidateAll()`/
  `unregisterFromCondition()` (confirmed by reading `src/dcps/waitset.zig` directly) drop it
  from every attached `WaitSet` cleanly, no dangling pointer regardless of destruction
  order. But that machinery is purely internal Zig-side bookkeeping with **no C-ABI-visible
  signal at all**, confirmed by reading the same file — so a binding relying on
  `attach_condition()` implicitly keeping a reference alive gets no error, nothing.
  Confirmed via `zzdds-examples/spikes/python/probe4_condition_ownership.py`: `--vanish`
  wraps a `GuardCondition` handle in a class whose `__del__` destroys it (the natural,
  RAII-shaped thing a binding author would plausibly write), attaches it, drops the only
  reference, and shows the condition silently vanishes from `WaitSet.get_conditions()` —
  no exception, the `WaitSet` itself never notices anything unusual happened. `--crash`
  shows the sharper edge of the same root cause: if anything else also captured the raw
  handle before the wrapper was collected (plausible — cached elsewhere, logged, handed to
  a second API) and tries to use it afterward, that's a genuine use-after-free — confirmed
  via a clean, symbolized Zig panic (not just a bare segfault):
  `DDS_GuardCondition_set_trigger_value` → `zidl_rt.unboxAs` reads a freed handle's
  now-garbage vtable pointer (`panic: incorrect alignment`). This is a different shape of
  gap than the listener finding, not a duplicate of it: there's nothing analogous to
  `release_listener_data` to fix it *with* today, for any binding, in any language. The
  real lever is a binding-side design choice — a wrapper for `ReadCondition`/
  `QueryCondition`/`StatusCondition` can sidestep this entirely by never auto-destroying on
  wrapper GC (their real DDS owner reclaims them eventually regardless), but `GuardCondition`
  has no fallback owner, forcing a binding to choose between premature-destruction risk
  (auto-destroy on GC, as tested here) and a permanent leak risk (never auto-destroy, app
  forgets to call an explicit destroy). The standard mitigation for the former is the same
  acquire/release keep-alive shape as the listener finding, but self-imposed and
  self-triggered off the binding's own `attach_condition`/`detach_condition` call sites —
  not something zidl can generate a shared hook for today, unlike listeners, unless a future
  round adds a condition-side equivalent of `release_listener_data`.
- **Two review-readiness follow-up confirmations (2026-08-12), `probe5_waitset_lifetime_and_
  typesupport_ctx.py`**: (1) `zzdds_register_type_support_ctx`'s `ctx_deinit` hook was
  reasoned to be structurally identical to a listener's `release_listener_data` back when the
  listener finding was written up, but never independently tested — now confirmed under the
  same GC+heap-churn pressure that broke the naive listener case: registering a second
  `TypeSupport` under the same `type_name` correctly supersedes the first and fires its
  `ctx_deinit` exactly once, `ctx` intact. (2) `WaitSet` has the identical no-factory,
  app-owned shape as `GuardCondition` (confirmed: `zzdds_create_waitset()`, no factory) — the
  scarier untested variant was whether destroying it while another thread is *actively
  blocked inside* `wait()` (not just idle) crashes. It doesn't: a background thread 0.5s into
  a real 10s `DDS_WaitSet_wait()` call survived the `WaitSet` being destroyed out from under
  it via a GC-triggered wrapper on the main thread, riding out its own timeout and returning
  `DDS_RETCODE_TIMEOUT` cleanly. Recorded as one confirmed-safe interleaving, not an
  exhaustive proof — no TSAN, no randomized timing stress, no concurrent attach/detach mixed
  in.
- **Not attempted by the Python spike**: literal heartbeat-thread respawn via real matched
  pub/sub, async-runtime-friendly event delivery (asyncio-idiomatic queuing vs. synchronous
  upcall), and `ReadCondition`/`QueryCondition`/`StatusCondition` ownership specifically
  (only `GuardCondition`, the sharpest case with no fallback owner, was actually probed) —
  see the spike's own README for what each would additionally need. Zero-copy/borrowed-data
  across the C-ABI (the Rust `zig-ffi` question) *was* subsequently attempted — see below,
  not still open.

**Follow-up spikes (2026-08-12): Go, Rust `zig-ffi`, and Haskell — `zzdds-examples/
{go,rust,haskell}/spike/`.** Prompted by the same question that started the Python spike:
does the binding set validated so far actually cover the usage patterns the languages still
on the list would need, before this review locks in scope? Same throwaway-probe economy
throughout (hand-declared FFI against zzdds's existing C-ABI, no real bindings, no codegen).
Full detail in each spike's own README; summary per language:

- **Go** (`zzdds-examples/spikes/go/`) — picked over C# specifically because CPython's non-moving,
  refcounted heap (which every Python finding implicitly relies on) is not a guarantee Go's
  runtime shares; worth checking directly rather than assuming Python's findings generalize.
  `probe1_attach`: no attach step needed (cgo's `//export` mechanism just works for a
  foreign OS thread it's never seen), and Go's runtime is more efficient about it than
  Python's — one goroutine gets created and *reused* across every call from the same foreign
  OS thread, unlike Python's fresh `_DummyThread` per call. `probe2_ctx_handle`: the sharper
  result, and a pleasant surprise — Go's default `cgocheck` (no opt-in needed) already
  catches the naive "raw Go pointer smuggled into a C struct field passed to a cgo call"
  mistake immediately and deterministically (confirmed 2/2 runs, identical message), as a
  *recoverable* panic (`cgo argument has Go pointer to unpinned Go pointer`) — stronger,
  louder protection than ctypes gives Python for the equivalent error, because `cgocheck`
  recursively scans struct fields being passed to a cgo call, and zzdds's own C-ABI shape
  (ctx living inside the listener struct passed to `create_datareader`) means the dangerous
  pointer and the call that would leak it cross the boundary together. `cgo.Handle` (an
  opaque `uintptr`-backed token, immune to the scan by design, confirmed by contrast) is the
  correct pattern and survived 11 consecutive GC+heap-churn cycles cleanly. Caveat recorded,
  not confirmed either way: `cgocheck` is a boundary-crossing check, not an ongoing
  invariant — it cannot catch "C copied this pointer elsewhere and used it later," a
  narrower residual risk than initially assumed, not fully closed.
- **Rust `zig-ffi`** (`zzdds-examples/spikes/rust/`) — targets the specific question of whether zzdds's
  *existing* `take_loaned`/`return_loan` C-ABI contract (valid until an explicit release
  call) maps onto a real, borrow-checker-enforced Rust lifetime, deliberately independent of
  whether the loan is backed by real zero-copy yet (it isn't — see zzdds's own roadmap; the
  *contract shape* is what's under test, not today's storage). `LoanedSample<'a>`, a
  `MutexGuard`-shaped RAII guard, returns `return_loan` via `Drop` (stronger than C/C++/
  Java's manual-call contract — survives early returns and panics) and ties `.data()`'s
  lifetime to the guard's own borrow, not the outer reader's. Real end-to-end run against
  the live C-ABI verified the payload byte-for-byte; a deliberate escape attempt
  (`examples/escape_attempt.rs`, storing the loaned slice outside the guard's own block) was
  rejected by the compiler with a precise, on-point `E0597` error, not a generic "can't
  return a local reference" rejection. Real bug found in the process, unrelated to Rust
  itself: `zzdds_take_loaned_raw`'s return convention is its own (`1` = success), not the
  standard `DDS_ReturnCode_t` (`0` = OK) every other zzdds C-ABI function uses — undocumented
  in `zzdds_c.h`'s comment for this function, confirmed only by reading
  `src/c_abi/bootstrap.zig` after the first version of the probe got it backwards. Verdict:
  the `zig-ffi` backend's core safety proposition is not a design risk against the existing
  loan API; the two open items are narrower (fix/document the retcode inconsistency, and
  real zero-copy landing underneath is a separate, larger zzdds-core question this spike
  doesn't block on either way).
- **Haskell** (`zzdds-examples/spikes/haskell/`) — this roadmap's own Haskell section previously covered
  only the CDR/type-mapping layer, nothing about reaching the DCPS core at all; this spike
  fills that gap directly. A second real ABI bug found by running rather than reading:
  `zzdds_factory_is_nil` returns C `bool` (1 byte); declaring it `CInt` (4 bytes) in the FFI
  import silently captured garbage from the rest of the return register for what was
  actually a valid, non-nil handle (read back as `871572480`) — fixed via `CBool`, the
  correct `Foreign.C.Types` mapping; flagged as a generalizable pitfall for any FFI language
  doing hand-written, header-independent type declarations, not Haskell-specific despite
  surfacing here first. Threaded RTS (`-threaded`): works exactly as documented, and reveals
  a third distinct runtime bookkeeping pattern alongside Python's (fresh thread-state object,
  same OS thread) and Go's (one goroutine, reused) — GHC creates a **new** `ThreadId` on
  *every single call* from the same recurring foreign OS thread. Non-threaded RTS: the
  identical source did **not** hang, crash, or visibly corrupt state — a genuinely surprising
  result against GHC's own documentation, reported with an explicit caveat rather than taken
  as license to treat `-threaded` as optional: this probe only ever has *one* recurring
  foreign OS thread calling in, never two *different* foreign threads entering concurrently,
  which is the specific, well-documented danger the threaded RTS exists to prevent — not
  constructed here, left as the most valuable unattempted follow-up. `StablePtr` (GHC's
  purpose-built keep-alive primitive, the direct equivalent of a JNI global ref or a Python
  registry entry): survived 14/14 checks under the same aggressive GC+heap-churn pressure
  used everywhere else, no exceptions. No adversarial "wrong way" contrast probe was built,
  unlike Python/Go — ordinary `Foreign.*` code has no direct equivalent of
  `unsafe.Pointer(&x)` or a ctypes `py_object` escape to even attempt the naive mistake with,
  itself worth recording as a point of relative confidence, reasoned from the API surface
  rather than independently confirmed.

**Explicitly out of scope for this entry:** no decision was made in this section about
which tradeoff to keep, which to fix, or what a unified design would look like — that
review happened separately and is recorded in full in the next section.

---

## Binding design review: decision (2026-08-12)

**Review complete. Decision: fix the anchor identity bug at its root (the C-ABI box
representation), not by adding a parallel return-side cascade; ship it Condition-family-
first; leave everything else on the prep section's list an explicit, scoped follow-on
rather than one bundled change.** This section resolves every item the prep section
(above) left open, with a rationale for each, and lists what actually needs to be built
next. It does not re-derive the prep work — see the section above and
`zzdds/docs/roadmap.md`'s "WaitSet / condition example" for the underlying evidence this
decision is based on.

### The anchor case: root cause identified, target design decided, not yet implemented

**Root cause, precisely stated:** a C-ABI handle *is* the address of a heap-allocated
`EntityBox{ptr, vtable}` (`zidl/packages/zidl-rt/src/entity_box.zig`). `unboxAs(T, handle)`
performs a **blind, unchecked reinterpret** of `box.vtable` as `*const T.Vtable` — there is
no runtime type tag anywhere in the box. This is only safe today because every
`get_c_abi_handle` call site boxes using a vtable *instance* whose static shape already
matches exactly the interface it was asked for — e.g. `GuardConditionImpl`
(`zzdds/src/dcps/waitset.zig`) declares two independent, hand-populated `DDS.*.Vtable` const
instances, `vtable` (GuardCondition-shaped: `get_trigger_value, set_trigger_value, deinit,
get_c_abi_handle, as_Condition`) and `cond_vtable` (Condition-shaped: `get_trigger_value,
deinit, get_c_abi_handle`), each with its own `CachedCAbiHandle` field (`gc_c_abi`,
`cond_c_abi`) and its own `get_c_abi_handle` implementation. Two boxes, two addresses, for
one object — that's the entire bug, confirmed by reading the actual field declarations, not
inferred.

**Why "just reinterpret one box's vtable pointer as the other's" doesn't work:** confirmed
by direct field-order comparison, not assumed. zidl flattens an interface's `Vtable` struct
as `[ops (bases-first, own last), attrs, deinit, get_c_abi_handle, as_{Base}...]`
(`zidl/src/backend/zig.zig`'s `emitInterface`). Because `deinit`/`get_c_abi_handle`/
`as_Base` are appended *after* all ops including the derived interface's own, they land at
different struct offsets for a base vs. any derived interface that adds even one op of its
own — which is the norm, not the exception (`GuardCondition` adds `set_trigger_value`,
`ReadCondition` adds four members, `QueryCondition` adds three — `zzdds/idl/dcps.idl` lines
274-325). Reinterpreting a `GuardCondition.Vtable*` as a `Condition.Vtable*` and calling
`.deinit()` through it would actually invoke `set_trigger_value` with the wrong signature —
silent memory corruption, not a crash you could count on. This is exactly the hazard
`emitInterface`'s own comment already calls out for *secondary* bases (`Topic : Entity,
TopicDescription`); it turns out to apply to every base once trailing synthetic slots are
accounted for, not just multi-inheritance cases. So the prep section's "unify per-view
caching so every view boxes to the same address" option, taken literally as raw-pointer
reinterpretation, is ruled out.

**Target design: a second, boxing-only "Views" indirection, orthogonal to the existing flat
dispatch vtable.** Leave the flat `Vtable` structs and every ordinary `.vtable.op(...)` call
site (the entire rest of generated code) untouched — this only touches `get_c_abi_handle`
and the box/unbox boundary. Per interface `I`, generate a second, tiny struct:
- root interface (no base): `IViews = extern struct { flat_vtable: *const I.Vtable }`
- single-base interface (base `B`): `IViews = extern struct { base: BViews, flat_vtable: *const I.Vtable }`

Because an `extern struct`'s first field is always at offset 0, nesting composes: for *any*
ancestor `A` reachable by always following the primary/first-listed base, `@ptrCast`-ing a
`*const LeafViews` to `*const AViews` and reading `.flat_vtable` lands on the correct,
unique storage for `A`'s own flat vtable pointer, regardless of how many levels deep the
real concrete type is (verified by hand for the whole Condition chain: `Condition <-
{GuardCondition, StatusCondition, ReadCondition} <- QueryCondition`, all single-base, per
`dcps.idl`). A concrete impl then needs exactly **one** `CachedCAbiHandle` field, not one
per view, and exactly one static `LeafViews` instance; every ancestor view's
`get_c_abi_handle` slot calls the same cache with the same `ptr`/`&leaf_views`.
`unboxAs(T, handle)` changes from "reinterpret `box.vtable` as `T.Vtable`" to "reinterpret
`box.vtable` as `T.CAbiViews`, then read `.flat_vtable` back out" — everything downstream
of that (the actual op dispatch) is unchanged.

**Layout assumption confirmed via a real Zig 0.16.0 spike (2026-08-12), not just reasoned
about.** `extern struct`'s first-field-at-offset-0 guarantee composing through 2 levels of
nesting (the `Condition <- ReadCondition <- QueryCondition` depth, the deepest chain in
`dcps.idl`'s Condition family) was verified with 5 real tests, not assumed:
`@ptrCast`/`@alignCast`-reinterpreting a `*anyopaque`-erased leaf `QueryConditionViews`
pointer as `*const ConditionViews` (2 hops up) correctly recovers the root's own
`flat_vtable` field, confirmed both by value and by `@offsetOf` (`ConditionViews.flat_vtable
== 0`, `GuardConditionViews.base == 0`, transitively for all four Views types), and by
exercising the exact type-erasure round-trip `unboxAs` will actually do (`*anyopaque` in,
`@alignCast` + `@ptrCast` out). All 5 tests pass. De-risks Phase 1 before any real codegen
or `waitset.zig` changes are made.

**This also resolves the prep section's "return-value adaptation cascade" question — no
cascade needed, in either direction.** The prep section named "parameter adaptation tries
harder than return adaptation" (`collectBaseImplementors`'s dynamic-cast-style cascade
exists only for parameter unboxing) as its own axis, worth fixing independently. It
doesn't need fixing: `WaitSet.wait()`/`get_conditions()` already dispatch
`get_c_abi_handle` through whatever vtable the *object's own* native fat pointer carries —
Zig-native dispatch was never broken. Once every ancestor view's `get_c_abi_handle` shares
one cache, that existing dispatch automatically returns the identical box regardless of
which view asked, with no new runtime type tag or trial-classification logic anywhere.
Building a return-side cascade to mirror `collectBaseImplementors` would have duplicated
machinery to solve a problem that's better solved by not creating divergent boxes in the
first place — recorded here as a correction to the prep section's framing, not a second
fix on top of the Views redesign.

**Expected free propagation to C++ (and likely Java) — worth confirming during
implementation, not yet verified.** C++'s `_getOrCreate` (`ConcreteImplGenerator`) keys its
`weak_ptr<Impl>` cache purely off the raw C-ABI pointer *value* it's handed. Since that
value becomes identical across views once the Zig-side box is unified, `_getOrCreate`
should start returning the same `shared_ptr` for both views with zero C++ backend changes —
the whole reason to fix this at the root instead of patching each binding's own
wrapper-identity layer independently. Flagged as an expectation to confirm once Phase 1
(below) lands, not confirmed today.

**Known limitation this design does not solve, called out explicitly rather than silently
dropped:**
- **Secondary bases** (`Topic : Entity, TopicDescription` — `TopicDescription` is Topic's
  second listed base) don't get the nesting trick; Topic keeps an independently-cached box
  for its `TopicDescription` view exactly as today. Not a regression — Topic has no
  reported identity bug, and this matches zidl's own existing reasoning for why raw pointer
  reinterpretation can't apply to non-primary bases.
- **Embedded-substruct impls break the "one `ptr` per object" assumption.**
  `QueryConditionImpl` doesn't have its own `cond_c_abi`/`rc_c_abi` — it delegates to
  `self.rc.cond_c_abi`/`self.rc.rc_c_abi`, where `rc` is a `ReadConditionImpl` *embedded by
  value* inside `QueryConditionImpl` (`zzdds/src/dcps/waitset.zig`). The natural pointer for
  `QueryConditionImpl`'s `ReadCondition`/`Condition` views is `&qc.rc` — a different address
  than `&qc` itself, the address used for `QueryConditionImpl`'s own `QueryCondition` view.
  A single shared box requires picking one canonical `ptr` (the outer object's own address,
  `&qc`, not `&qc.rc`) for every view and having the leaf's dispatch functions do their own
  internal offset math to reach the embedded field — the same thing the `owner_qc`
  back-pointer fix (`zzdds/docs/roadmap.md`'s "QueryCondition deleted via its spec-correct
  ReadCondition upcast corrupts memory") already had to do for `deinit`. Not attempted as
  part of this decision; `QueryConditionImpl` needs its own pass when the Condition family
  is converted (Phase 1 below) — flagged now so it isn't rediscovered as a surprise
  mid-implementation.

**Phasing — deliberate, not everything at once:**
1. **Phase 1 — Done (2026-08-12).** `Condition`/`GuardCondition`/`StatusCondition`/
   `ReadCondition`/`QueryCondition`, the reported bug.

   **What actually shipped, vs. what was planned above — one real design change from the
   plan.** `zidl_rt.unboxAs` was left completely unchanged; a new, separate
   `zidl_rt.unboxAsView(comptime T, handle)` was added alongside it
   (`zidl/packages/zidl-rt/src/entity_box.zig`) instead. Reason found during implementation:
   `unboxAs` is generic infrastructure called for *every* interface across the whole
   codebase, but only 5 interfaces are converting in Phase 1 — changing `unboxAs`'s own
   contract would have forced every other concrete impl (`DataReader`/`DataWriter`/`Topic`/...)
   to switch to the `CAbiViews` box representation simultaneously, in this same change, months
   before Phase 2. A new `@shared_c_abi_box` IDL annotation (`zidl/src/ir/types.zig`'s
   `hasSharedCAbiBox`, mirroring the existing `@callback`/`isCallbackInterface` pattern
   exactly) marks which interfaces opt in; zidl's Zig backend emits the nested `CAbiViews`
   type only for annotated interfaces (`emitInterface`) and picks `unboxAs` vs. `unboxAsView`
   per call site based on the *target* interface's own annotation, not the enclosing
   operation's interface (`cAbiUnboxFnName`, threaded through `emitCApiOp`/`emitCApiAttr`/
   `emitCApiAsBase`/the listener-trampoline emitter) — necessary because e.g.
   `WaitSet.attach_condition`'s own interface (`WaitSet`) isn't annotated, but its `Condition`
   *parameter* is, and needs the new unboxing on that parameter specifically. `zzdds/idl/
   dcps.idl` annotates the 5 Condition-family interfaces; `zzdds/src/dcps/waitset.zig`'s four
   impl structs collapsed from 2 `CachedCAbiHandle` fields to 1 each.

   **`QueryConditionImpl`'s embedded-`rc`-field wrinkle — resolved via new thunk vtables, not
   attempted lightly.** True full identity sharing (QueryCondition/ReadCondition/Condition
   views of one QueryCondition all present the *same* box) needed more than reusing the
   existing `owner_qc` back-pointer as a signal: `ReadConditionImpl.vtGetCAbiHandleReadCondition`/
   `vtGetCAbiHandleCondition` now redirect to `owner_qc`'s own shared box+`views` when set,
   but that box's `.ptr` becomes the *outer* `QueryConditionImpl` (`&qc`), not the embedded
   `&qc.rc` — meaning the ReadCondition/Condition-shaped functions reached through that box
   can't be `ReadConditionImpl.vtable`/`.cond_vtable` (which assume `ctx` is `*ReadConditionImpl`).
   `QueryConditionImpl` gained its own `rc_thunk_vtable`/`cond_thunk_vtable` — safe to call
   with `ctx = *QueryConditionImpl` — reusing its existing `vtGetTrigger`/`vtGetSampleMask`/
   etc. (already `ctx`-generic) directly, with new thunk-specific `get_c_abi_handle`/
   `as_Condition` bodies. Native Zig-to-Zig dispatch (`toCondition()`/`vtAsReadCondition()`,
   `WaitSetImpl`'s own attach/detach/notify plumbing) is completely untouched by any of this —
   only the C-ABI box-creation path was ever wrong.

   **Real bugs found fixing this — all in hand-written code `zig.zig`'s codegen sweep
   couldn't reach, confirmed via real crashes, not by inspection:**
   - `zzdds/src/c_abi/extensions.zig`'s `zzdds_destroy_guardcondition`/
     `zzdds_guardcondition_is_nil` (hand-written factory-less bootstrap, see "WaitSet /
     condition example") and its four `DDS_Condition_as_DDS_{GuardCondition,StatusCondition,
     ReadCondition}`/`DDS_ReadCondition_as_DDS_QueryCondition` checked-downcast functions
     (hand-written, `zig.zig`'s C-API generator has no visibility into which concrete zzdds
     struct backs a vtable) all still called the old `unboxAs` directly on now-annotated
     types — `zzdds_destroy_guardcondition` crashed with a general-protection fault calling
     through a garbage `.vtable` read out of a misinterpreted `CAbiViews` payload; the
     downcast functions silently always returned "not a match" (comparing a misinterpreted
     pointer against a real vtable address, always unequal). Fixed by switching each to
     `unboxAsView`.
   - `zzdds/src/c_abi/bootstrap.zig`'s `unboxReadCondition` (backs `take_w_condition_raw`/
     `take_next_instance_w_condition_raw`/`read_next_instance_w_condition_raw`) assumed a
     standalone `ReadCondition` and a QueryCondition's embedded one "produce the same
     vtable" to tell them apart from other condition kinds — true before this fix, *newly
     false* after it (the `owner_qc` redirect above makes them genuinely distinguishable,
     which is what the fix is *for*), so the function needed updating to recognize both
     shapes explicitly and recover the embedded `&qc.rc` in the second case. Surfaced as 4
     failing tests (wrong sample counts, `expected 1, found -1`), not a crash.
   - `DDS_ReadCondition_as_DDS_QueryCondition`'s own doc comment explaining why it always
     returns null ("no safe way to recover... without a runtime type tag neither struct
     carries") is now partially stale — a real distinguishing signal exists post-fix. Left
     unimplemented deliberately (a distinct, smaller fix, not required by this bug); comment
     updated to say so rather than left incorrect.

   **Verified:** a new C-ABI-level regression test (`zzdds/test/c_abi/bootstrap_test.zig`,
   "WaitSet.wait() returns the SAME boxed C-ABI handle...") asserts real boxed-handle pointer
   equality between a `GuardCondition`'s own creation box, its `Condition`-view upcast box,
   and what `wait()` returns for it — confirmed to actually catch the bug by deliberately
   re-breaking the fix once and observing the test fail (a segfault, in this case) before
   reverting, matching this project's own established practice. Full build+test matrix green:
   plain, `-Dc-binding`, `-Dcpp-binding`, `-Djava-binding`, and `-Dsanitize-thread` (TSan),
   in both zidl and zzdds. Two unrelated test crashes surfaced during this work (one TSan,
   one in `participant_vtable_test`'s timer/listener-reentrancy teardown test, neither in code
   this change touches) — investigated via repeated runs on both the pre-change and
   post-change tree (11+ clean repeats total, one-off on each), consistent with pre-existing
   timing-sensitive flakiness rather than a regression, not chased further as part of this
   change.
2. **Phase 2 — Done (2026-08-12).** Extended the collapse to every other entity impl
   (`Entity`/`DomainParticipant`/`Publisher`/`Subscriber`/`DataWriter`/`DataReader`/`Topic`/
   `TopicDescription`/`ContentFilteredTopic`/`DomainParticipantFactory`), plus a second scope
   decided at the start of this pass, not in the original Phase 1 write-up: the `ZZDDS.*`
   vendor-extension layer (`zzdds.idl`'s `DomainParticipantFactory`/`DomainParticipant`/
   `Topic`/`DataWriter`/`DataReader`, each a real `ZZDDS.X : DDS::X` single-base derived
   interface) got the identical treatment, since it has the identical bug and shares the
   identical mechanism. This is also the decision on the prep section's "listener trampolines
   may have a latent version of the same cross-view identity gap" open question — closed as a
   corollary, not a separate fix, confirmed by the existing generic listener-trampoline
   unboxing code (added in Phase 1, keyed off each parameter's own annotation) picking up the
   newly-annotated types automatically, no further codegen changes needed.

   **Real findings from doing this at a larger scope than Phase 1's single-file Condition
   family — each confirmed via a real build/crash/test failure, not by inspection:**
   - **Cross-module `@shared_c_abi_box` annotations were silently discarded, breaking every
     `ZZDDS.*` interface's nesting — a real zidl bug, not a Phase 2 oversight.**
     `Builder.resetNonCallbackInterfaces` (`zidl/src/ir/builder.zig`) resets an imported
     interface's `.raw` (its annotations) back to an empty Pass-1 skeleton after the fill
     pass, for every cross-module interface — a deliberate, previously-correct choice for
     `.operations`/`.attributes`/etc. (avoids growing hand-written vtable literals for
     content nothing asked for), but it silently took `.raw` down with it. `.bases` had
     already been carved out as an exception once before, for the identical reason
     (`nativeHandleBase` needing a cross-module base's real inheritance chain — see that
     fix's own doc comment) — `.raw` needed the same exception, for `hasSharedCAbiBox`.
     Confirmed via real generated output: `ZZDDS.DataReader.CAbiViews` had no `base` field
     at all before the fix, silently degrading to a root (un-nested) shape with no error.
     Fixed by sparing `.raw` from the reset too, alongside `.bases` — zidl's own test suite
     stayed fully green, confirming this was safe to spare generally, not just for this case.
   - **A real, if easily resolved, file-organization wrinkle: a concrete impl's third
     (`ZZDDS.*`) view lives in a different file (`extensions.zig`) than its first two
     (`DataReaderImpl`/etc. in `reader.zig`/etc.), which already imports the impl file —
     naively adding the reverse import for the shared `views` reference would be circular.**
     Tested deliberately before committing to it: Zig tolerates this cleanly (a `pub const`
     value reference isn't a struct-layout cycle, just lazily-resolved), confirmed with a
     real build before relying on it. `reader.zig`/`writer.zig`/`participant.zig`/`topic.zig`
     each import `extensions.zig` for exactly this reference; `writer.zig` already had this
     exact import for an unrelated existing reason (`DataWriterListenerEx`'s widen/narrow
     mechanism), which is what suggested trying it rather than restructuring file ownership.
   - **`DomainParticipantFactory`'s C-ABI identity is NOT one object with extra views, unlike
     every other type here — a real structural difference, found via investigation before
     any code was written.** `FactoryOwner` (`extensions.zig`) is the actual app-visible
     factory handle, presenting both `DomainParticipantFactory` views (`ZZDDS.*`/`DDS.*`) of
     itself — genuinely eligible for the same collapse. `DomainParticipantFactoryImpl`
     (`factory.zig`) is a *different* struct: an internal, per-`ParticipantStack` delegate
     `FactoryOwner` creates one of per participant/domain, never exposed as its own C-ABI
     handle to any caller — collapsing anything there, or unifying it with `FactoryOwner`'s
     box, would have been a correctness bug (conflating two distinct objects' identities),
     not a fix. Left untouched, correctly.
   - **A hand-written checked-downcast function's own doc comment went stale as a direct,
     positive consequence of this fix, in a way worth flagging generally: fixing a cross-view
     identity bug can retroactively invalidate an "no reliable way to tell these apart"
     assumption written before the fix existed.** `unboxReadCondition` (`bootstrap.zig`,
     Phase 1) assumed a standalone `ReadCondition` and a `QueryCondition`'s embedded one
     "produce the same vtable" — true before Phase 1's `owner_qc` redirect, newly false
     after it (confirmed via 4 real failing tests, wrong sample counts). Generalized here:
     every hand-written function bypassing `zidl_rt.unboxAs`/`boxEntity` with its own
     manually-constructed box (test fixtures included — several `zidl_rt.boxEntity(alloc,
     ptr, someImpl.vtable)` call sites in `bootstrap_test.zig`/`typesupport_test.zig` needed
     updating to `&someImpl.views`) needs auditing whenever a new interface gets annotated,
     not just the interface's own generated call sites.
   - **`nil.zig`'s nil-entity sentinels were never touched by Phase 1 and were a real,
     confirmed-via-crash gap, not just a theoretical inconsistency — folded into this pass
     at the user's direction.** Every nil sentinel (`nil_condition`, `nil_guardcondition`,
     `nil_participant`, `nil_topic`, ... — `src/dcps/nil.zig`) boxed via the old bare-vtable
     scheme; the moment any hand-written call site switched to `unboxAsView` (this pass's
     Task 12), passing a nil handle through it crashed for real (a `nil_participant`-derived
     box, general-protection fault reconstructing `.vtable`). Fixed the same way as the real
     impls — each nil sentinel that's `@shared_c_abi_box`-annotated got its own `CAbiViews`
     wrapper, nested to match its real base chain; `extensions.zig`'s separate nil-`ZZDDS.*`
     statics (`nil_zzdds_participant_c_abi`, etc.) got matching treatment, reusing `nil.zig`'s
     already-`pub` nil singletons (`nil.nil_entity.vtable`, etc.) as their base-chain vtables
     rather than exposing new internals. `MultiTopic`/`WaitSet` nil sentinels untouched
     (neither interface is annotated — `MultiTopic` unimplemented, `WaitSet` has no
     multi-view identity concern to begin with).
   - **A real, easily-made scoping mistake, caught by the build, not by review:**
     `DomainParticipantFactory` itself (`dcps.idl`) was initially left unannotated while its
     `ZZDDS.DomainParticipantFactory` wrapper was annotated — compiled, but
     `ZZDDS.DomainParticipantFactory.CAbiViews` silently came out root-shaped (no `.base`),
     caught immediately by the first real build attempting to use it. A reminder that
     annotating only the "outer" interface in a base chain is a silent, not a loud, mistake
     — every interface in a chain that's meant to share identity needs its own annotation.

   **Verified:** full build+test matrix (plain, `-Dc-binding`, `-Dcpp-binding`,
   `-Djava-binding`, `-Dsanitize-thread`) green in both repos, on a clean rebuild (not just
   incrementally — this phase hit real stale-cache confusion mid-implementation from
   incremental builds after IDL edits, worth remembering for next time). A new C-ABI-level
   regression test (`bootstrap_test.zig`, "DataReader's Entity, DataReader, and
   ZZDDS.DataReader views all share the SAME boxed C-ABI handle") proves the fix across the
   full 3-level, cross-module chain — confirmed to actually catch the bug by deliberately
   re-breaking it once (this time a clean assertion failure, not a crash) before reverting.
3. **Not attempted, not scheduled:** Topic's secondary-base (`TopicDescription`) view stays
   independently cached, permanently, per the limitation above.

### Cross-repo audit (2026-08-12, after Phase 1+2 landed) — what else this touches

**`dds-rtps` — confirmed unaffected, no action.** It consumes zzdds as a native Zig package
(`@import("zzdds")`) for its `shape_main` interop-test binary, never crosses the C-ABI at
all, and never touches `WaitSet`/condition types — outside the blast radius on two
independent grounds. Pinned to a tagged zzdds release (not a path dependency), so it
wouldn't pick up this work even if it were relevant.

**`zzdds-examples` — all three (C, C++, Java) workarounds now removed.** (Java's own gap
was structural, not just unfixed — see its own entry below for why removing it needed new
native-side infrastructure, not just a rewrite of the example code.)
- `c/waitset/` (`src/publisher.c`, `src/subscriber.c`) — **removed, verified 2026-08-12.**
  C's opaque-handle model has no wrapper cache: `wait()` returns raw `DDS_Condition`
  handles directly, and the box-identity fix makes those handles `==`-comparable against
  whatever a held `DDS_GuardCondition`/`DDS_ReadCondition`/`DDS_QueryCondition` upcasts to.
  Rebuilt against the fixed zzdds, ran publisher+subscriber pairs twice (two domains),
  both fully clean — workaround deleted, `README.md` updated to say so.
- `cpp/waitset/` (`src/publisher.cpp`, `src/subscriber.cpp`) — **first attempt reverted
  (see below), then removed for real, verified 2026-08-12 (later the same day).** First
  pass confirmed the workaround could NOT be removed yet: each condition subtype kept its
  own independent `_getOrCreate` cache, so `wait()`'s `shared_ptr<ConditionImpl>` and
  `dw->get_statuscondition()`'s `shared_ptr<StatusConditionImpl>` were never the same
  object even with the raw handle unified — swapping in `wait()`-membership comparison
  made `publisher.cpp` busy-spin on a live run, reverted via `git checkout`. Root cause was
  exactly the pre-existing "C++ backend: entity/entity-sequence *return* values never
  recover a more-derived concrete type" gap documented above (found 2026-08-10) — the
  box-identity fix operates one layer below where this problem actually lives. Rather than
  leave the workaround in place, implemented the real fix (this section's "shared-family
  `_getOrCreate` cache" update, above) and re-applied the membership-based rewrite: rebuilt,
  ran publisher+subscriber pairs twice (two domains), both fully clean including through
  `qc_cond`'s two-level identity chain — workaround deleted for real this time, `README.md`
  updated.
- `java/waitset/` (`Publisher.java`, `Subscriber.java`) — **first checked NOT removable
  (see below), then removed for real, verified 2026-08-12 (later the same day).** First
  pass confirmed Java's gap was worse than C++'s, not the same shape: Java's JNI bridge had
  no wrapper-identity cache at all, not even a per-concrete-type one — `zidl_java_box_
  <c_name>` (`src/backend/java.zig`) constructed a brand-new Java object with `NewObject`
  on *every* handle crossing, no caching, and generated entity classes got no `equals()`/
  `hashCode()` override, so `wait()`'s returned `Condition[]` was structurally unable to
  `==`/`.equals()` a previously-held condition reference. Rather than leave the workaround
  in place, implemented the real fix (this section's "Java backend: native weak-global-ref
  box cache" update, below) and rewrote both files to branch on `List.contains()`
  (reference-identity `equals()`, no override needed): rebuilt, ran publisher+subscriber
  pairs twice (two domains), both fully clean, including through `GuardCondition`'s
  hand-constructed registration path and `qcCond`'s `QueryCondition`-satisfies-
  `ReadCondition` identity (Java's own interface inheritance) — workaround deleted for
  real, `README.md` updated.
- `zig/waitset/` never had the bug (native fat-pointer comparison, no boxing) — no change
  needed, and its `build.zig.zon` already path-depends on zzdds directly, so it's already
  building against this fix on every rebuild.
- `c/waitset/README.md` and `java/waitset/README.md` both say the workaround was copied
  "not because [C/Java] was confirmed to have the identical gap" — stale as of the Python
  spike (which did confirm it at the raw C-ABI level for every opaque-handle binding, not
  just C++). Worth a wording fix independent of whether the workaround itself is removed
  yet.
- The `python`/`go`/`haskell` spike READMEs describe the identity gap as open/unresolved —
  accurate when written, now missing a pointer to this decision. Low priority (throwaway
  probe code), not deep-audited.

**Doc staleness found in *this* repo's own worked examples — both fixed.**
`zzdds/docs/language-bindings.md`'s `DDS_Topic_get_name` example (`unboxAs` →
`unboxAsView`, since `Topic` is now annotated) — fixed. `zidl/docs/ecosystem.md`'s
`--zig-generate-c-api` walkthrough had the same class of staleness (`zidl_rt.unboxAs
(DDS.Publisher, ...)`-style examples for now-annotated interfaces) — also fixed (uses
`unboxAsView` throughout now, plus its own "Cross-view identity" explanatory paragraph).

**Confirmed: no binding API surface changed.** Verified directly (`git diff` across this
whole two-phase change), not just reasoned about: zero `pub export fn` signature additions/
removals/changes anywhere, zero changes under `include/`, and the IDL diff is purely
`@shared_c_abi_box` annotation lines plus comments — no operation/parameter/return-type
touched. Any binding (including ones not covered above) can pick up this fix by rebuilding
against a newer zzdds; nothing about how they call it needs to change.

**Factory-less entity bootstrap (`WaitSet`/`GuardCondition`) — generate it.** Decision: yes,
zidl should detect "interface has no factory operation anywhere in the IDL, and is not
itself a pure base interface" and generate the repetitive wiring — C header declaration,
`--generate-c-api` export wrapper, C++ friend-factory wrapper, Java JNI native method plus
registration — behind an explicit new flag (e.g. `--generate-factoryless-bootstrap`),
consistent with the Plugin Architecture section's existing philosophy ("new
implementation-specific needs should still land as explicit, mechanism-only flags"). This is
not zzdds-specific policy — "no factory op, not a base interface" is a generic IDL-shape
observation any DDS implementation (or non-DDS IDL user) could hit — so it belongs in zidl
core, not a future plugin. Scope: zidl generates the wiring only; zzdds still hand-writes
the one canonical Zig constructor per factory-less interface (already exists for both
`WaitSet`/`GuardCondition`) that the generated wiring calls into — this turns "three
hand-written bootstraps" into "one hand-written Zig constructor, zero hand-written wiring,"
not zero hand-written code entirely.

**Update (2026-08-13): mechanism revised — annotation, not a global auto-detect flag. Still
not implemented; this only changes the design of what would eventually get built.** The
"detect the shape, gate behind a flag" mechanism above was reconsidered while scoping
whether `DomainParticipantFactory` fits the same pattern (it structurally does — no factory
op for it either, same hand-written-times-three shape). Two reasons to prefer a per-interface
annotation (e.g. `@factory_less_bootstrap(ctor = "createWaitSet")`, riding the same generic
`.raw` mechanism `@shared_c_abi_box`/`@callback` already use, no new CLI flag needed at all
— interpreted by whichever generation pass, `--zig-generate-c-api`/`--cpp-generate-impl`/the
Java JNI bridge, is already running) instead:

- **The auto-detect heuristic is exactly the class of thing that's caused real bugs in this
  codebase already**, more than once, this session alone: `entity_base_ifaces`/
  `ifaceOwnsNativeHandle` misclassifying `ReadCondition` as a non-leaf (a real crash, see "C
  and C++ backends" below), and `resetNonCallbackInterfaces` wrongly stripping `.raw`/
  `.bases` for cross-module interfaces (silently dropping `@shared_c_abi_box` across an
  import boundary until caught). "No factory op + not a pure base interface" is the same
  *kind* of structural classification — flip a global flag on and it applies uniformly to
  everything matching the heuristic, `DomainParticipantFactory` included, whether or not
  that's actually correct for it (see the roadmap entry below: it isn't, without further
  work `DomainParticipantFactory` isn't in scope for this — its `DDS`-base/`zzdds`-extension
  duality and `FactoryOwner`'s internal complexity mean the mechanism as designed for
  `WaitSet`/`GuardCondition` doesn't automatically generalize to it correctly). An
  annotation sidesteps the classification question entirely: `WaitSet`/`GuardCondition` get
  marked when this lands; `DomainParticipantFactory` doesn't, until/unless someone
  deliberately extends the mechanism *and* marks it — no heuristic to get subtly wrong on a
  future interface that happens to match the same shape.
- **A global flag has no way to carry the one piece of information the codegen actually
  needs**: which specific hand-written Zig constructor to call for a given interface
  (`zzdds_create_waitset` vs. `zzdds_create_guardcondition` — no naming convention reliably
  derives one from the other). The alternative to an IDL-colocated annotation parameter is a
  CLI-side mapping, and `--cpp-impl-override <Interface>=<Class>` already shows that path's
  friction firsthand — it needed a whole companion flag (`--cpp-impl-include`) just to make
  the override class visible to the generated file that references it. Keeping this
  configuration in the IDL, next to the interface it describes, avoids reproducing that.

**`DomainParticipantFactory` — deliberately NOT included in this decision, scoping recorded
for whenever the mechanism above actually gets built.** Checked rather than assumed: it is
*not* a singleton (`extensions.zig`'s `createFactory` does `alloc.create(FactoryOwner)`
fresh on every call), so it doesn't carry the wrapper-identity-fragmentation risk a true
per-process singleton would under naive "always construct fresh" codegen — that specific
concern doesn't apply. What does: unlike `WaitSet`/`GuardCondition` (no `zzdds.idl`
counterpart at all), `DomainParticipantFactory` is simultaneously a `DDS`-namespace base
type *and* a `zzdds`-namespace vendor extension of it, and the generated bootstrap would
need to know which one it's constructing and how that interacts with
`--cpp-impl-override`/`DomainParticipantFactorySupport`'s *compose*, not inherit, shape —
a real wrinkle the mechanism as scoped for `WaitSet`/`GuardCondition` doesn't address. It's
also built on `FactoryOwner`, which already carries more internal complexity than a plain
single-impl entity (the explicit constraint that it must never be identity-unified with the
separate, internal per-`ParticipantStack` `DomainParticipantFactoryImpl` delegate). Recorded
recommendation: `WaitSet`/`GuardCondition` get the annotation first, as the clean minimal
instance of the pattern; `DomainParticipantFactory` stays hand-written-times-three until
someone deliberately extends the mechanism to handle the vendor-extension case, rather than
being swept in by a heuristic the moment the flag (now: annotation) exists.

**Listener callback keepalive — one shared per-language helper per future binding, not a
zidl-generated cross-language mechanism.** The prep spikes confirmed the *shape* is
identical everywhere (acquire a keep-alive token at registration, release it at the two
points core already calls `release_listener_data`) but the *primitive* is irreducibly
language-specific (Python: per-registration dict, Go: `cgo.Handle`, Haskell: `StablePtr`) —
nothing to generate uniformly across them. Decision: for each future binding that needs one,
build a single shared runtime-library helper (mirroring Java's existing
`zidl_java_release_listener_data` — one implementation, not reinvented per call site), with
the **per-registration, not per-listener-identity** keying the Python spike's follow-up
refinement established as a hard requirement of the design (a dict keyed by listener-object
identity breaks the ordinary "same listener registered on two entities" case). This is a
template for whenever Python/Go/Haskell/C# backends actually get built, not work to do now —
no such backend exists yet.

**No C-ABI equivalent of `release_listener_data` for `WaitSet`-attached conditions — Done
(2026-08-12), landed on request rather than opportunistically as originally planned.**
`WaitSetImpl.conditions` (`zzdds/src/dcps/waitset.zig`) changed element type from a bare
`DDS.Condition` to a new `AttachedCondition{cond, release_ctx: ?*anyopaque, release_fn: ?*const
fn(?*anyopaque) callconv(.c) void}` — a plain `attach_condition()` leaves both fields null;
the new `WaitSetImpl.attachConditionWithRelease` (shared internally by both `vtAttach`, which
calls it with null/null, and the new hand-written export below) populates them. The release
fires exactly once, whichever of the three ways an attachment actually ends: explicit
`detach_condition()` (`vtDetach`), the `WaitSet` itself being destroyed while still attached
(`reallyDeinit`), or the condition itself being destroyed while still attached
(`vtInvalidateHandle`, reached via the existing `WakeupList.invalidateAll()` path). New
hand-written C-ABI export (alongside `zzdds_create_waitset`, same reasoning): `DDS_ReturnCode_t
zzdds_waitset_attach_condition_with_release(DDS_WaitSet, DDS_Condition, void *release_ctx,
zzdds_condition_release_fn release_fn)`, declared in `zzdds/include/zzdds_c.h`. Re-attaching an
already-attached condition (with either the plain or the `_with_release` op) is a no-op, same as
today — deliberately does not update or replace an existing registration, to avoid silently
dropping the original release.

**One real correctness subtlety, caught during design before any code was written, not by
review after the fact:** the release callback is arbitrary caller-supplied code that must be
free to reentrantly call back into the same `WaitSet` (attach/detach another condition, even
destroy it) without deadlocking — so it must never fire while `WaitSetImpl.mu` (or any other
lock this file takes) is held. `vtDetach`/`vtInvalidateHandle` both needed restructuring
(capture the removed entry, release the lock, fire the callback after) to make this true,
while `unregisterFromCondition`'s own call *stays* inside the lock exactly as before — moving
it outside too would have introduced a real TOCTOU race against a concurrent `vtAttach`
re-attaching the same condition in the gap, which would wrongly strip out the fresh
registration `unregisterFromCondition`'s deferred call didn't know about yet. `reallyDeinit`
needed no such restructuring: by the point it runs, the existing `EntityQuiesce` mechanism
already guarantees exclusive access to `self.conditions`, the same invariant that already let
it skip locking `self.mu` at all before this change.

**Verified:** four new C-ABI-level tests (`zzdds/test/c_abi/bootstrap_test.zig`) — one per
teardown path, plus one proving a redundant re-attach doesn't silently replace the original
registration — each confirmed to actually catch its own removal by deliberately re-breaking
that one call site and observing the corresponding test fail, before reverting. Full
build+test matrix (plain, `-Dc-binding`, `-Dcpp-binding`, `-Djava-binding`) green, plus three
consecutive clean `-Dsanitize-thread` (TSan) runs given the lock-ordering-sensitive nature of
the change.

**Update (2026-08-13): both wired up now — C++ and Java.** The "not done as part of this"
note below described the hook as built but unused; the user asked to close that gap, for
both bindings the Python spike's `--vanish`/`--crash` findings applied to.

- **C++**: `zzdds_cpp.hpp`'s `WaitSetSupport` (already the class that owns `~WaitSet`'s
  `zzdds_destroy_waitset` call) now overrides `attach_condition()`, calling
  `zzdds_waitset_attach_condition_with_release` and holding a `shared_ptr<Condition>`
  keepalive in a `std::unordered_map` keyed by the resolved raw handle, released via the
  hook's callback. No override of `detach_condition()` needed — the plain inherited one
  already fires the same release callback, since it's the same underlying C-ABI
  attachment record. The raw-handle resolution mirrors (duplicates, not reuses — that one
  lives inline in an unnamed lambda) the `dynamic_cast` cascade `WaitSetImpl::
  attach_condition`'s own generated body already has. Verified with a real test, not just
  a compile check: a standalone program using `std::weak_ptr` to observe the C++ wrapper
  object's own lifetime directly — confirms it survives after the app drops its own
  `shared_ptr` post-attach, and confirms it's released on explicit detach, on the
  `WaitSet` itself being destroyed while still attached, and that a redundant re-attach
  doesn't leak a second registration. Deliberately re-broke it (reverted the fix via `git
  stash`, confirmed the same test now fails at exactly the expected assertion, restored)
  before considering it verified.
- **Java**: no C++-style virtual dispatch to override, and no `--java-impl-override`
  equivalent exists for `dcps.idl`-level types — so this hooks in via JNI's
  `RegisterNatives` instead, in `zzdds_java_runtime.c` (hand-written, not codegen),
  overriding `WaitSetImpl`'s generated `n_attach_condition` native binding with a
  replacement that holds a JNI global ref per attached condition in a hand-rolled native
  linked-list keepalive (same shape as the shared-family box cache above, minus the
  weak-ref part — this one wants a *strong* reference), released via the same C-ABI hook.
  Registered lazily from `createWaitSet()`'s native implementation (guarded by
  `pthread_once`, since that's always called before any app could have a `WaitSet` to
  attach anything to) rather than at `JNI_OnLoad`, which zidl's own generated bridge
  already owns exclusively. Completely transparent to callers — `WaitSetImpl.java`'s
  public `attach_condition()`/`detach_condition()` methods are unchanged; only which
  native implementation backs the private `n_attach_condition` dispatch point changes.
  Verified the same way as C++: a standalone Java program using `WeakReference` +
  `System.gc()` to observe the Java wrapper object's own collection directly, covering the
  same four scenarios (survives app drop, released on detach, released when the `WaitSet`
  itself is destroyed while still attached, no leak on redundant re-attach) — and the same
  deliberate-re-break discipline (temporarily disabled the `RegisterNatives` call,
  confirmed the test fails at the expected assertion, restored).

**ABI-marshaling pitfalls — both done (2026-08-13).** Two real, narrow bugs found by the
spikes, neither related to the design questions above:
- **Non-standard raw-take/read retcode convention — fixed, full normalization, larger
  scope than originally scoped here.** The original framing ("`zzdds_take_loaned_raw`'s
  non-standard `1`=success retcode... no known external consumer exists yet... only the
  throwaway Rust spike calls it") turned out to be wrong when actually checked: the
  `1`=success/`0`=no-data/negative=error convention is shared by **5** sibling C-ABI
  functions (`zzdds_take_one_raw`/`_instance`, `zzdds_read_one_raw`/`_instance`,
  `zzdds_take_loaned_raw`), not just the one named, and it's baked directly into the core
  generated `<Type>DataReader_take()`/`_read()`/`_take_next_instance()`/`_read_next_instance()`/
  `_take_loaned()` API in both the C and C++ backends — the single most commonly-used read
  path in the whole ecosystem, not an isolated corner. A narrow fix (only
  `zzdds_take_loaned_raw`) would have left 4 siblings on the old convention, a worse
  inconsistency than the status quo — asked the user, who chose full normalization instead.
  All 5 zzdds functions and their generated C/C++ typed-reader wrappers now use
  `DDS_ReturnCode_t` uniformly (`DDS_RETCODE_OK`=0 sample taken, `DDS_RETCODE_NO_DATA`=11
  none available, `DDS_RETCODE_BAD_PARAMETER`/`DDS_RETCODE_OUT_OF_RESOURCES` for real
  errors) — documented in `zzdds_c.h`'s comment right above the declarations, as
  originally asked. Fallout fixed across the ecosystem: `zzdds/test/c_abi/bootstrap_test.zig`
  (15 call sites), `java_runtime/zzdds_java_runtime.c` (2 call sites — Java's own `.take()`
  already abstracted the retcode into a `null`/`Sample` API, unaffected at the Java
  language level, but its native glue needed the same fix), the Rust spike
  (`zzdds-examples/spikes/rust/`, both the `ffi.rs` declaration and `loan.rs`'s consumer —
  confirmed via a real `cargo run`, not just a type-check), and `zzdds-examples/c/
  hello_world/subscriber.c` (a **real regression this fix would otherwise have
  introduced** — its `if (rc != 0)` treated any nonzero as fatal, which used to be safe
  since empty-queue was `0` too, but would now abort on ordinary "no more samples yet";
  fixed to check `DDS_RETCODE_NO_DATA` explicitly first). Also found, while auditing every
  consumer rather than assuming safety: `zzdds-examples/c/shape/shape_main.c` and `cpp/
  custom-allocator/subscriber.cpp`/`c/custom-allocator/subscriber.c` were already written
  in terms of `DDS_RETCODE_OK`/named constants (apparently anticipating this exact fix
  ahead of time) — meaning `shape_main.c` was silently **broken** under the old convention
  (`rc != DDS_RETCODE_OK` rejected real successful takes, which used to return `1`, not
  `0`) and this fix genuinely repairs it, confirmed via a real two-process live run
  receiving actual shapes. One more real regression caught the same way, in `cpp/
  opencv_zzdds/video_roi_display.cpp`'s `take_loaned(loan) != 1` (would have permanently
  rejected the frame path) — fixed and confirmed via a clean CMake build against real
  OpenCV. Every touched consumer's stale explanatory comments (describing the old
  ambiguity as a still-live issue) updated to match, not just the code.
- **`bool` (1 byte) vs. `int`-width (4 byte) FFI type mismatches — documented.** Added a
  paragraph to `zzdds/docs/language-bindings.md`'s "C binding API design" section
  (found via Haskell's `zzdds_factory_is_nil` `CInt`-vs-`CBool` bug), generalized beyond
  Haskell/that one function: the risk applies to any hand-written, header-independent FFI
  binding for any of zzdds's `bool`-returning functions.

**Rust `zig-ffi` loan/lifetime design — confirmed sound, no action.** The spike validated
that the existing (non-zero-copy) `take_loaned`/`return_loan` contract maps cleanly onto a
real Rust lifetime; real zero-copy landing underneath remains a separate, larger
zzdds-core question already tracked elsewhere, not blocked by or blocking this review.

**Allocator tiering — preserved, not incidentally broken.** `CachedCAbiHandle.get`/`.free`
already take an `alloc: std.mem.Allocator` parameter; the Phase 1/2 collapse to one field
per concrete type doesn't change that — explicitly confirmed as a constraint carried
forward, not something the redesign gets to relitigate.

**Zig-native `as_{Base}` ergonomic convenience method — add it.** Small, low-risk, decided
yes: zidl's Zig backend should emit a top-level convenience wrapper (not just the vtable
slot it already emits) so pure Zig-native callers get the same ergonomic upcast every other
binding already has.

**Un-swept box cache memory tradeoff for short-lived conditions — Closed (2026-08-12), not
pursuing.** Revisited after landing the `WaitSet`-attached-condition release hook above,
prompted by a direct question about whether it's actually a real problem. Conclusion: the
concern as originally framed ("workloads that create/destroy many short-lived
`GuardCondition`s or `ReadCondition`s rapidly") doesn't hold up against how `GuardCondition`
is actually meant to be used. The realistic hot path is high-frequency *signaling* of one
long-lived condition — `zzdds-examples/zig/waitset`'s own watchdog-thread pattern (the thing
that motivated making `trigger` atomic in the first place) creates one `GuardCondition` and
calls `set_trigger_value()` on it repeatedly; that's a plain atomic write that never touches
the box cache at all. An application that instead creates/destroys a fresh `GuardCondition`
per event already pays for far more expensive things on that same path — the impl struct's
own allocation, taking `WaitSetImpl.mu`, appending to its `conditions` list, registering a
`WakeupHandle` in a mutex-guarded array — all of which dwarf the box's one small alloc/free
pair. Pooling the box specifically wouldn't move the needle for that workload; an application
actually needing that throughput has the wrong tool (`WaitSet`/`Condition` was never meant to
be a lightweight semaphore) and needs a different primitive or to reuse one condition, not a
faster box cache. Not reopening unless a real profile someday shows the box itself — not the
surrounding entity/mutex machinery — as the actual bottleneck.

**"Nearest enclosing non-null listener" DDS conformance gap (`zzdds/docs/roadmap.md`,
2026-08-12 entry) — not this review's problem to fix, but confirmed not to conflict with
anything decided here.** It's a DCPS correctness question (whether a `Subscriber`'s
listener gets invoked when its child `DataReader` has none installed), not a C-ABI/
binding-shape question — triage (fix vs. defer) belongs on zzdds's own roadmap, independent
of this decision. The one thing worth confirming now: implementing it later would introduce
a new "whose `ctx` is this" shape (one physical listener struct invoked with a *different*
entity's handle as argument) — the listener-keepalive design decided above (per-registration
keying, not per-listener-identity) already accommodates this, since a single listener object
serving as fallback for multiple child entities is exactly the "same object registered on
two entities" case that keying decision was already built to handle. No design change
needed, just confirmed compatible.

**Process note, not an architecture decision:** several of this round's real fixes lived
only as uncommitted local zidl changes, consumed by zzdds via a temporary `.path` override.
**Repeated deliberately for Phase 1 (2026-08-12):** `zzdds/build.zig.zon`'s `.zidl`
dependency is once again a `.path = "../zidl"` override (was pinned to the tagged
`v0.3.4-zig.0.16.0` release before this), confirmed resolving correctly (`zig build`/
`zig build test` both clean against the live local zidl checkout, no hash field needed for
a path dependency). Recommend cutting a zidl release promptly after Phase 1 lands and
reverting to the tagged `.url`/`.hash` form, rather than accumulating another long-lived
local-checkout dependency — a workflow suggestion, not something this review is deciding.

---

## Embedded / MicroZig / XRCE Roadmap

**Status:** `--profile xrce` exists and validates important XRCE constraints before
backend generation: only `@final` types, bounded strings/sequences, no maps, no optional
members, no wstring, and no TypeObject/TypeIdentifier output. The Zig backend now accepts
`--zig-version 0.15.1` and emits bounded sequence/string code that uses fixed-capacity
`zidl_rt.BoundedArray` storage instead of heap-backed containers.

This is the first MicroZig-enabling slice, not a complete freestanding output mode yet.
zidl itself still builds with Zig 0.16.0; the 0.15.1 target is for generated Zig code and
`zidl-rt` consumers.

Remaining work:
1. ~~Add a committed compile fixture that generates XRCE-profile Zig and checks it with the
   Zig 0.15.1 toolchain.~~ **Done** — `test/xrce-microzig/` exists with a committed
   `types.idl`, generated `types.zig`, and `test.zig`; not yet wired into `zig build
   integration-test`.
2. Split generated Zig runtime assumptions into a full runtime path and a constrained
   XRCE-client path.
3. Define the no-heap writer/reader surface expected by MicroZig clients; current generated
   bounded-field storage is heap-free, but CDR buffers still use the normal runtime model.
4. Audit generated code and `zidl-rt` APIs for freestanding compatibility.
5. Add XRCE-client-focused fixtures that exercise bounded-only IDL on embedded-friendly
   generated output.
6. Keep DDS-XRCE agent/broker work separate from zidl unless codegen needs explicit hooks.
   zidl should generate client-side type support; the agent can live in a DDS implementation
   or a separate repository that consumes zidl output.

---

## Known Gaps and Deferred Work

Existing-backend features that have `// TODO` or deferred markers in the code or
documentation, are not intentionally omitted, and are not yet tracked elsewhere in
this roadmap. New language backends have their own sections below.

**C++ backend: `--generate-interfaces`'s generic complex-type adapter (`cpp.zig`'s
`ImplGenerator`/`generateImplSource`, several `/* TODO: adapt C++ types to C ABI */`
sites) silently returns a default value for params/returns that aren't scalar/entity/
string — confirmed dead code for zzdds, verified 2026-08-07, not a live gap.** Checked
against zzdds's own `build.zig`: every `--generate-interfaces` invocation without
`--cpp-generate-impl` (lines ~741/749 for `dcps.hpp`/`zzdds.hpp`, ~588/600 for the
allocator-smoke test) only installs/consumes the generated `.hpp` header — any `_impl.cpp`
those runs might also emit is never added to a compile step. zzdds's real, shipped entity
implementation exclusively comes from the separate `--cpp-generate-impl` runs, which
dispatch to `cpp.zig`'s `ConcreteImplGenerator` (a completely different code path,
gated specifically on `generate_interfaces and !cpp_generate_impl`). So this stub is
real but unreachable for zzdds today; documented in `features.md` as a known limitation
for any consumer that *does* use bare `--generate-interfaces` without
`--cpp-impl-override`/`--cpp-generate-impl`. Re-raise only if such a consumer appears, or
if a real IDL operation with a non-scalar/entity/string parameter needs generic
(non-override) C++ interface adaptation.

**C++ backend: entity/entity-sequence *return* values never recover a more-derived
concrete type, only entity *parameters* do — real gap, fixed 2026-08-12 (see the update
below).** Found building
zzdds-examples' `cpp/waitset` (2026-08-10): `WaitSet::wait()`/`get_conditions()`'s
generated C++ bodies always box each returned `Condition` via
`::DDS::ConditionImpl::_getOrCreate` (the base interface's own default concrete class) —
unlike entity *parameter* adaptation (`attach_condition`'s cascade, see "C and C++
backends" above), there's no attempt to try `GuardConditionImpl`/`StatusConditionImpl`/
`ReadConditionImpl`/`QueryConditionImpl` instead. Combined with each condition-family
interface's C-ABI handle being cached independently *per view* (zzdds's
`GuardConditionImpl.gc_c_abi` vs `.cond_c_abi`, e.g.), a `Condition` returned from
`wait()` can never be `std::shared_ptr`-identity-equal to (or `dynamic_pointer_cast`-
recoverable as) the concretely-typed shared_ptr an application originally attached, even
though both refer to the same underlying condition — breaking the standard DDS idiom of
iterating `active_conditions` and comparing against held condition objects. See zzdds's
own roadmap (WaitSet/condition example entry) for the full writeup and the workaround
`cpp/waitset` uses instead (branching on each held condition's own `get_trigger_value()`
directly). A real fix needs either a return-path implementor cascade (determining which
concrete class a bare `DDS_Condition` handle was *really* boxed from isn't information
the handle alone carries — would need a runtime "what interface is this" tag/query) or
unifying per-view C-ABI handle caching so every view of the same object boxes to the
same address — a real design question, not a mechanical fix. Zig-native code is
unaffected (native `{ptr,vtable}` values compare directly, no boxing involved) — this is
specific to crossing the C ABI. Likely affects C and Java too (unverified — `c/waitset`/
`java/waitset` don't exist yet); re-raise there once they do.

**Update (2026-08-12), after the box-identity fix landed and `c/waitset` was built:
confirmed C is *not* affected, confirmed C++ still is.** The box-identity fix (this
section's own "Binding design review: decision") unifies the raw C-ABI handle itself, so
C — which has no wrapper-object layer on top, just the raw handle — genuinely benefits:
`wait()`'s returned `DDS_Condition` is now `==`-comparable against a held condition's own
upcast handle, verified end-to-end in `zzdds-examples/c/waitset` (workaround removed).
C++ does *not* benefit, because the gap described above lives one layer up, in
`_getOrCreate`'s per-concrete-type caching — the raw handle being unified doesn't help
when `wait()` only ever constructs the *base* `ConditionImpl` type regardless. Confirmed
by trying the removal against `zzdds-examples/cpp/waitset` and reverting (see zzdds's own
cross-repo audit entry). Java doesn't benefit either, and for a more fundamental reason
than C++: it has no wrapper-identity cache at all (not even per-type) — every handle
crossing into Java allocates a fresh object, and generated classes have no `equals()`/
`hashCode()`, so even same-type same-handle lookups from two different call sites are
never identity-equal. Confirmed by codegen inspection (`src/backend/java.zig`), no live
run needed — see `java/waitset/README.md`. **Both gaps are now fixed — see the two
"Update (2026-08-12, later the same day)" entries below.**

**Update (2026-08-12, later the same day): the C++ gap above is fixed — shared-family
`_getOrCreate` cache.** The user asked to implement the real fix rather than leave the
workaround in place, for both C++ (as designed in conversation) and Java (see the next
update). Root cause, precisely: `ConcreteImplGenerator` gave every concrete class its own
independent `_getOrCreate` with its own `static unordered_map<Handle, weak_ptr<T>>` cache
— even after the box-identity fix unified the raw handle, `wait()`'s hardcoded
`ConditionImpl::_getOrCreate` call and e.g. `StatusConditionImpl::_getOrCreate` were
consulting two different maps, so they could never return the same C++ object.

Fix: new `interface.sharedCAbiBoxFamilyRoot`/`collectSharedCAbiBoxFamilies` (mirrors
`zig.zig`'s own primary-base-chain walk for `CAbiViews` nesting, so the C++-level grouping
stays consistent with whichever views the Zig-level box-identity fix actually unified — a
secondary base like `Topic`'s `TopicDescription` correctly stays out of it). A family with
more than one member now shares ONE cache, owned by the family's root class and exposed
via two public `static` Meyer's-singleton accessors (`_familyMutex()`/`_familyCache()` —
thread-safe lazy init, no out-of-line data member definition needed). The root's own
`_getOrCreate` return type changes from `shared_ptr<RootImpl>` to `shared_ptr<RootIface>`
(the shared interface, not the root's own concrete class — a cache hit may genuinely be a
sibling object) — confirmed behavior-preserving for every existing call site, since an
op's declared return type / a sequence element / a listener parameter always immediately
upcasts a `_getOrCreate` result into the interface type anyway, never the concrete class.
Every non-root sibling keeps its own signature but now consults the root's shared cache,
recovering its own concrete type via `dynamic_pointer_cast` on a hit (safe, not just
hopeful: the only thing that could ever have populated the cache with an object that's
actually-at-runtime that sibling's class is that sibling's own `_getOrCreate`, on a
previous call for the same handle).

Real-spec fallout once regenerated against zzdds: 4 multi-member families fell out of the
real IDL, not just the Condition family this was designed around — `Condition` (5:
Condition/GuardCondition/StatusCondition/ReadCondition/QueryCondition), `Entity` (7 in
dcps.idl alone, growing to 11 once zzdds.idl's `zzdds::DomainParticipant`/`Topic`/
`DataWriter`/`DataReader` join via their primary `DDS::X` base), `TopicDescription` (2:
TopicDescription/ContentFilteredTopic), and `DDS::DomainParticipantFactory`/
`zzdds::DomainParticipantFactory` (2). The Entity family turned out to matter for a real
reason beyond WaitSet: `StatusCondition::get_entity()` returns a generic `Entity` too.

One real bug found and fixed during this work, the kind only a real build catches: the
new `_familyMutex()`/`_familyCache()` accessor *declarations* live in the header (unlike
the old per-class cache, entirely hidden inside the `.cpp` as a function-local static) —
`std::mutex`/`std::unordered_map` need to be complete types there now, not just in the
`.cpp`. Missed initially; `zig build -Dcpp-binding=true install` didn't catch it (lucky
transitive include from something else in the same translation unit), but a standalone
`g++ -c dcps_impl.cpp` did, and so did zzdds-examples' own `cpp/waitset` CMake build
(different translation unit, unlucky). Fixed by adding `<mutex>`/`<unordered_map>` to the
generated header's own includes unconditionally (matching `<memory>`, already
unconditional there) rather than only the `.cpp`'s existing conditional include.

Two types needed hand-written-glue changes on top of the codegen fix, since they're
never wrapped via any *generated* `_getOrCreate` at all: `GuardCondition` (app-instantiated
directly per spec, no factory operation in dcps.idl) and zzdds.idl's four extension types
(`TopicSupport`/`DataWriterSupport`/`DataReaderSupport`/`DomainParticipantSupport`, each
composing a fully-implemented `DDS::*Impl` per `--cpp-impl-override` rather than being
constructed through the generated path) — see zzdds's own roadmap entry for the
`zzdds_cpp.hpp` side of this. Verified end-to-end: `zig build test` and `test-bindings`
green, a standalone `g++ -c` compile of the regenerated `dcps_impl.cpp` clean, and
`zzdds-examples/cpp/waitset` rebuilt with its workaround actually removed (not just
attempted) — two consecutive clean runs, zero `FAIL` lines, including through `qc_cond`'s
two-level `QueryCondition` → `ReadCondition` → `Condition` identity chain.

**Update (2026-08-12, later the same day): the Java gap above is fixed — native
weak-global-ref box cache.** Java's problem was more fundamental than C++'s (no
wrapper-identity cache at all, not per-type), so the fix looks different, but the shape of
the solution is the same idea: give `zidl_java_box_<c_name>` (the JNI bridge's per-handle
"construct a Java object" helper) a cache shared across every member of a
`@shared_c_abi_box` family, instead of unconditionally constructing fresh every time.

Since JNI is plain C, "shared cache" here means real hand-rolled native infrastructure,
not a language-provided container: `emitSharedFamilyCache` (`src/backend/java.zig`) emits,
once per multi-member family, a singly-linked list of `{void *handle, jweak ref}` nodes
protected by one `pthread_mutex_t` (a hash table was considered and rejected — realistic
family sizes are small; a linked list is simpler to get right and to audit). Double-checked
locking, not lock-held-across-construction: `zidl_java_box_<c_name>` looks up under the
lock, releases it, calls `NewObject` (a real Java constructor, which can run arbitrary code
— including re-entering this file's own native methods — so nothing holds the mutex across
it), then re-locks and checks again before inserting, discarding its own object in favor of
a winner if another thread raced ahead. Keyed directly on the raw `void *` handle with *no*
per-view conversion step, unlike C++: this backend's box functions already take a bare
`void *`, and `@shared_c_abi_box` already guarantees that value is numerically identical
across every view.

Two real bugs found and fixed, both compile-time, both only caught by an actual build (not
`zig build test`'s own suite, which has no multi-member family in its golden-test IDL):
- A `*/` inside a doc-comment string being generated (`zidl_java_box_*/lookup calls`)
  closed the C block comment early, turning the rest of the comment into garbled top-level
  C — cascaded into unrelated-looking parse errors several hundred lines later in the same
  file. Fixed by rewording the comment (`zidl_java_box_* / lookup calls`).
- `familyOf` originally treated "does `self.families` have >1 entries for this root" as
  sufficient to share a cache — true within one file, but zzdds.idl's `DomainParticipant`/
  `Topic`/`DataWriter`/`DataReader` all walk up into dcps.idl's `Entity` (a root neither
  file's `.c` output shares with the other), and among *themselves alone* already number
  >1 in zzdds.idl's own generation pass — so both dcps.idl's and zzdds.idl's separately
  generated `.c` files independently decided to define the SAME non-`static` function/mutex
  names for `Entity`'s family, colliding at link time the moment both landed in
  `libzzdds_jni.so` (`ld.lld: duplicate symbol`, a real failure, not a hypothetical one).
  Fixed by requiring a family's root to be *locally declared* in the current file
  (`local_entity_names`) before treating it as shared; a family whose root is foreign (like
  zzdds.idl's case) now falls back to independent per-member behavior instead of a
  duplicate-defining shared one — not a full fix for that specific cross-file case
  (mirrors zzdds_cpp.hpp needing its own separate glue for the analogous C++ situation),
  but correct and collision-free.

One hand-written-glue registration needed on top of the codegen fix, same shape as C++'s
`GuardConditionSupport`: `ZzddsRuntime.createGuardCondition()`'s native implementation
(`java_runtime/zzdds_java_runtime.c`) constructs its Java object directly (`GuardCondition`
has no factory operation in dcps.idl) rather than through any generated box helper, so it
now calls a new `extern`-declared `_zidl_family_DDS_Condition_register_external` (emitted
alongside the rest of the shared-cache infra specifically for this "hand-written glue needs
to participate too" case) to register itself into the same cache `wait()`'s generic
`zidl_java_box_DDS_Condition` consults.

Verified: `zig build test`/`test-bindings` green (including the Java smoke test), `zig
build -Djava-binding=true install` clean, and `zzdds-examples/java/waitset` rebuilt with
its `get_trigger_value()` workaround replaced by `List.contains()` membership checks — two
consecutive clean runs (two domains), including through `GuardCondition`'s registration
path and `qcCond`'s `QueryCondition`-satisfies-`ReadCondition` identity (Java's own
interface inheritance, no upcast needed unlike C/C++).

**Update (2026-08-13), PR #39 Greptile review — two findings, one real fix + one corrected
doc comment.** PR #39 (the C++/Java shared-family cache work above) drew a Confidence 4/5
review with a MUST-FIX and a lower-priority follow-up.

1. **MUST-FIX, confirmed real and fixed: single-value entity returns/attributes had no
   most-derived box resolution.** The Java shared-family cache above is keyed on the raw
   `void *` handle — correct for making repeated boxes of the *same* handle identity-equal,
   but orthogonal to a different bug: `zidl_java_box_<C>` boxes a handle as whatever `C` the
   call site's *declared* return type says, not the handle's real runtime type. Sequence
   elements already handled this correctly (`SeqParamMarshalGenerator`'s
   `_box_as_most_derived` dispatcher, built for `WaitSet::wait()`'s `ConditionSeq`), but a
   bare (non-sequence) entity-typed op return or attribute getter — `StatusCondition::
   get_entity()` being the concrete case that surfaced it — called `zidl_java_box_<C>`
   directly. Consequence: the FIRST caller to box a given handle through the bare `Entity`
   type permanently wins the cache slot for that handle, and a later caller expecting to
   cast the result to the real derived type (`DataReader`, `Topic`, ...) gets a
   `ClassCastException` — confirmed reachable by reading the generated
   `Java_io_zzdds_dcps_StatusConditionImpl_n_1get_1entity` trampoline directly, not
   speculative.

   Fix: generalized the sequence-only dispatcher into a shared mechanism both call shapes
   use. New free functions in `java.zig` — `collectDerivedSiblings` (every other known
   entity interface with `target` as a transitive base, via `bases[0]`-and-beyond, i.e. the
   full base chain, not just the primary one — a handle's *declared* type doesn't constrain
   which of its real bases it might actually be), `mostDerivedBoxFnName` (names, doesn't
   emit, the right function: `zidl_java_box_<C>` directly if `target` has no derived
   sibling, else `<C>_box_as_most_derived`), and `emitBoxAsMostDerived` (extracted from
   `SeqParamMarshalGenerator`, now free and reusable). `JniBridgeGenerator` now forward-
   declares and unconditionally emits `<C>_box_as_most_derived` for every entity interface
   that has a derived sibling — same "always emitted, not just when the current file happens
   to use it" policy `zidl_java_box_<C>` itself already uses, so an unrelated file gaining a
   new call site later doesn't need this file regenerated too. `emitJniBridgeOp`'s entity
   op-return case and `emitJniBridgeAttr`'s entity attribute-getter case both now call
   through `mostDerivedBoxFnName` instead of hardcoding `zidl_java_box_<C>`.

   One golden fallout: `types.zig`'s `AdvancedGreeter : Greeter` now gets a
   `Greeter_box_as_most_derived` dispatcher emitted (unused in that golden file specifically,
   since nothing there returns a bare `Greeter` — emitted anyway per the unconditional
   policy above). One test updated to match (`java: bare sequence<Entity> param... gets real
   JNI marshaling` — `Entity_box_as_most_derived` is now expected to exist even though this
   test's own `DataReaderSeq` call site doesn't use it, since `Entity` has `DataReader` as a
   derived sibling in that test's IR). Verified: `zig build test` (1028 tests, all goldens)
   and a direct regeneration against zzdds's real `dcps.idl` both clean.

2. **Lower-priority follow-up, investigated and NOT fixed — the literal restriction as
   documented was wrong, enforcing it would have broken zzdds's real IDL.** Greptile flagged
   `hasSharedCAbiBox` (`src/ir/types.zig`) as having no enforcement of its documented
   hierarchy restriction ("a secondary base... must not be annotated"). Implemented the
   literal check (reject any interface using an `@shared_c_abi_box`-annotated interface as a
   non-primary base) — and running it against zzdds's real `dcps.idl` immediately failed on
   `Topic : Entity, TopicDescription`, where `TopicDescription` (Topic's secondary base) is
   deliberately `@shared_c_abi_box`-annotated. Cross-checked against this same roadmap file:
   already documented above (the C++ family-cache entry, "a secondary base like `Topic`'s
   `TopicDescription` correctly stays out of it") and in the box-identity section ("Not
   attempted, not scheduled: Topic's secondary-base (`TopicDescription`) view stays
   independently cached, permanently") as an intentional, permanent, working design choice,
   not a bug — every family-grouping walk (Zig's `CAbiViews` nesting, C++/Java's
   `sharedCAbiBoxFamilyRoot`) only ever inspects `bases[0]`, so a secondary-base annotation
   is inert (its own independent family), never silently mis-composed. The doc comment's
   "must not be annotated" was simply overstated. Reverted the validation entirely and
   rewrote `hasSharedCAbiBox`'s doc comment to describe the actual (harmless, intentional)
   behavior instead of a false restriction. No enforcement added — there is no invalid state
   left to reject once the doc comment matches reality.

**PL_CDR (RTPS ParameterList) codegen in non-Zig backends — not planned, verified out of
scope for all of them (C, C++, Java, and future Python/C#/Rust/Haskell alike).**
`--zig-pl-cdr` is a Zig-backend-only flag; every other backend parses and silently ignores
it, and that's correct, not a gap. Confirmed against zzdds (zidl's only real-world
consumer): `idl/rtps_discovery.idl`, the sole IDL file with PL_CDR-eligible `@mutable`
discovery types, is generated exclusively via `-b zig --zig-pl-cdr`
(`zzdds/docs/dev-notes.md`) — no non-Zig generation target exists for it. RTPS wire-level
SPDP/SEDP encode/decode happens entirely inside zzdds's Zig core
(`src/discovery/spdp.zig`/`sedp.zig`) and never crosses the C-ABI. The only place discovery
data reaches a binding is via `ParticipantBuiltinTopicData` and its siblings in
`idl/dcps.idl`, which are plain `@final` structs generated through the ordinary
(non-PL_CDR) path — by the time any binding sees discovery data it's already been decoded
by Zig and repackaged as an ordinary DDS-typed struct. Since RTPS discovery always runs in
the Zig core regardless of which language binding created the participant, no binding
backend needs its own PL_CDR codec — this applies uniformly, not just to C/C++. Re-raise
only if a consumer other than zzdds needs a non-Zig program to implement RTPS wire
discovery directly, without going through the Zig core.

### C and C++ backends

- **C++ backend: `collectBaseImplementors` wrongly excluded `ReadCondition` (and any
  other interface that's simultaneously "used as someone's base" AND "has its own real
  concrete implementor") from an interface's entity-parameter `dynamic_cast` cascade —
  fixed. Done.** Found while building zzdds-examples' `cpp/waitset` (2026-08-09/10),
  the first real exercise of `WaitSet::attach_condition`/`detach_condition` with a plain
  (non-`QueryCondition`) `ReadCondition` through any binding: `dynamic_cast<
  ::DDS::ReadConditionImpl*>` was simply missing from the generated `Condition`-parameter
  adaptation cascade (`ConditionImpl`, `GuardConditionImpl`, `StatusConditionImpl`,
  `QueryConditionImpl` were all tried; `ReadConditionImpl` never was), throwing
  `std::invalid_argument("zidl: incompatible entity implementation for DDS::Condition")`
  at runtime — confirmed via a real crash, not by inspection.

  Root cause: `collectBaseImplementors` (`src/backend/interface.zig`) took
  `entity_base_ifaces` as a parameter and skipped any interface it contained, on the
  reasoning that being "used as a base" meant an interface was purely a structural mixin
  with no leaf of its own — true for `Entity`/`TopicDescription`/`Condition`, but wrong
  for `ReadCondition`: `entity_base_ifaces` answers a narrower question
  (`ifaceOwnsNativeHandle`'s: does *this* interface need its own *virtual*
  `native_handle()`, or does a more-derived interface — `QueryCondition` — own a more
  specific one instead), not "is this interface ever the actual most-derived runtime
  type of an object." `ReadCondition` is legitimately excluded from the first question
  (so `QueryCondition` can declare its own `DDS_QueryCondition`-returning
  `native_handle()` instead of inheriting `ReadCondition`'s) but not the second —
  `create_readcondition()` returns a plain `ReadCondition` whenever the app doesn't ask
  for a `QueryCondition`, and `ReadConditionImpl` is a real, independently-constructible
  class with its own `_getOrCreate`, confirmed generated regardless of
  `entity_base_ifaces` membership (as are `ConditionImpl`/`EntityImpl`/
  `TopicDescriptionImpl` themselves — every non-callback interface gets its own concrete
  impl class unconditionally; there is no case where excluding an `entity_base_ifaces`
  member from `collectBaseImplementors` was ever actually correct).

  Fixed by dropping the `entity_base_ifaces` parameter from `collectBaseImplementors`
  entirely — every non-callback interface is now a valid cascade leaf, matching what the
  impl-class generator already does unconditionally. Verified: `zig build test` green
  (1008/1008, no golden fixture regression — none of zidl's own test IDL happened to
  have this specific "extended-and-independently-leaf" shape before); real end-to-end
  against zzdds — rebuilt `cpp/waitset` against a local zidl checkout, confirmed the
  crash reproduces on the pre-fix build and is gone after, 5+ consecutive real runs
  clean, plus valgrind (0 errors, 0 leaks) and a manual `-fsanitize=thread` build (no
  races, 2 runs).

- **Zig backend: a `sequence<EntityInterface>` typedef's C-ABI `_free` function used the
  native (fat-pointer) element size instead of the boxed (opaque-pointer) one — fixed.
  Done.** Found immediately after the fix above, building the same `cpp/waitset` example
  (2026-08-10): `DDS_ConditionSeq_free` (and every other `sequence<EntityInterface>`
  typedef's generated free function, `zig.zig`'s `is_unbounded_seq` code path) called the
  type's own native `.deinit()`, which frees `self._buffer[0..self._maximum]` using
  `DDS.Condition`'s native 16-byte `{ptr, vtable}` fat-pointer stride. That's correct for
  a `ConditionSeq` built directly by Zig-native code, but every instance a C/C++/Java
  caller actually holds was boxed down to one 8-byte opaque pointer per element by the
  existing entity-sequence C-ABI adaptation (the "`--zig-generate-c-api` bare
  `sequence<EntityInterface>` operation params" fix below, already shipped in
  `v0.3.2-zig.0.16.0`) before ever crossing the ABI — freeing it via the native stride
  requests double the correct byte range from the allocator. Confirmed via valgrind on a
  real crash (`munmap_chunk(): invalid pointer`, deterministically on every single call,
  not a rare race) inside a real `WaitSetImpl::wait()` C++ call — this is the first time
  `wait()`'s C-ABI output path was ever exercised end-to-end with real attached
  conditions, since nothing could construct a `WaitSet` through any binding before
  zzdds's own bootstrap-constructor work landed alongside this example.

  Fixed by detecting the same "is this a `sequence<EntityInterface>`" condition used
  elsewhere in this backend and, only for that case, emitting a `_free` body that
  reinterprets `_buffer` as `[*]?*anyopaque` (`@ptrCast`) before computing the free
  range, and frees only the buffer itself — never the individual boxed entity handles it
  points to, which are independently cached/owned via each entity's own
  `get_c_abi_handle()`. The native `.deinit()` method itself is untouched (still correct
  for its own, non-C-ABI callers). `emitStructCApiFree` (the sibling free-function
  generator for plain data structs with sequence fields) doesn't need the equivalent fix
  — a struct field can never be entity-interface-typed. Verified the same way as the fix
  above: real crash before, clean after, across 5+ runs, valgrind, and a manual TSAN
  build.

- **C++ backend: `--cpp-generate-impl` couldn't construct a vendor-extended entity impl —
  fixed via `--cpp-impl-override`/`--cpp-impl-include`. Done.** Found while porting
  zzdds-examples' `hello_world` to C++ (2026-08-04): `PublisherImpl::create_datawriter`
  and `DomainParticipantImpl::create_topic` (both in zzdds's generated `dcps_impl.cpp`)
  always construct the base `DDS::DataWriterImpl`/`DDS::TopicImpl`, never the
  vendor-extended `zzdds::DataWriterImpl`/`zzdds::TopicImpl` that zzdds's *separately
  generated* `zzdds_impl.hpp` declares (with `set_listener_ex`/`as_topic_description`).
  A caller's natural `static_pointer_cast<zzdds::DataWriterImpl>(dw)` compiles cleanly
  but is undefined behavior — confirmed by reproducing a segfault through a corrupted
  vtable, not just by inspection.

  Root cause is structural, not a missed call site: `--cpp-generate-impl` runs *twice*,
  completely independently — once over `dcps.idl` (→ `dcps_impl.cpp`), once over
  `zzdds.idl` (→ `zzdds_impl.cpp`). The `dcps.idl` pass has no way to know
  `zzdds::DataWriterImpl` exists; from its point of view `DDS::DataWriterImpl` *is* "the"
  concrete `DDS::DataWriter`. There's also no existing IDL-level escape hatch for this —
  `zzdds.idl` extends `DataWriter`/`DataReader`/`Topic`/`DomainParticipant`/
  `DomainParticipantFactory` individually, but nothing overrides the *factory methods*
  that construct them.

  **Scoped fix** (worked out with zzdds; see zzdds's own roadmap for the consumer side):
  two new flags on the `--cpp-generate-impl` pass being generated *from the base IDL*
  (i.e. passed alongside `dcps.idl`'s generation, not `zzdds.idl`'s):
  - `--cpp-impl-override <Interface>=<QualifiedClass>` (repeatable) — every site that
    would construct/return the default impl class for `<Interface>` (every
    `_getOrCreate` call for it) uses `<QualifiedClass>::_getOrCreate(...)` instead. The
    default impl class is still generated (unused, not deleted) — keeps the change
    additive, no "should this class still exist" question.
  - `--cpp-impl-include <header>` (repeatable) — adds an extra `#include` so
    `<QualifiedClass>` is visible.

  **The part that isn't just construction-site substitution**: `dcps_impl.cpp` also
  *consumes* entities constantly, via `dynamic_cast<DDS::TopicImpl*>(...)` in every
  parameter-adaptation lambda that recovers a native handle from a `shared_ptr<DDS::Topic>`
  argument (e.g. `create_datawriter`'s topic parameter). Once `create_topic` returns a
  `zzdds::TopicImpl` instead, those casts fail — `zzdds::TopicImpl` and `DDS::TopicImpl`
  are unrelated siblings, not parent/child. Fixing this does **not** require retrofitting
  multiple/virtual inheritance onto either class (that route was considered and dropped —
  diamond-shaped inheritance through the shared `DDS::Topic` base, needing every default
  impl class to switch to virtual inheritance just to support the rare extended case).
  Simpler and sufficient: when an override is registered for `<Interface>`, the
  parameter-adaptation lambda tries `dynamic_cast<QualifiedClass*>` as an additional
  fallback alongside the default class's cast. `zzdds::TopicImpl` needs no changes at all.

  Implementation note for whoever picks this up: route both the construction sites *and*
  the adaptation-lambda fallback through one central "resolve the concrete impl class name
  for interface X" function in `cpp.zig`'s impl generator, consulting the override table —
  don't hand-patch individual call sites, there are ~20 per entity kind across the file and
  missing one reintroduces the identity-cache-split bug this is meant to fix (a `_getOrCreate`
  call that's missed keeps populating the *default* class's cache instead of the override's,
  so the same native handle ends up with two non-identical wrapper objects).

  **This class of decision — "which concrete class backs abstract interface X" — is a
  DDS-implementation policy choice, not something zidl core should be accumulating
  hardcoded flags for indefinitely.** `--cpp-impl-override`/`--cpp-impl-include` were
  scoped as a general, blind (no cross-IDL parsing) *mechanism* specifically so a future
  zzdds-owned zidl plugin can drive them programmatically instead of a human hand-writing
  the override list in `build.zig` — see "Plugin architecture" below.

  **Implemented as scoped above, both flags landing exactly as designed**: `cpp.zig`'s
  `entityImplName()` is the single choke-point function consulting the override table,
  used by both `_getOrCreate` construction sites and `dynamic_cast` parameter-adaptation
  sites, matching the "route through one central function" implementation note above. No
  changes needed to the default (unoverridden) impl classes or to `zzdds::TopicImpl`
  itself, as predicted. Consumer side (zzdds's four hand-written `*Support` classes
  composing the base `DDS::*Impl`, plus the `build.zig` wiring) is done too — see zzdds's
  own roadmap "C++ ABI" entry for the verification detail (full 6-pair cross-binding
  matrix, zzdds's own test suite, `cpp/hello_world`'s raw-C-ABI workaround removed). Not
  yet in a tagged zidl release; zzdds's pin stays on `v0.3.1-zig.0.16.0` until one is cut.

- **`ZidlCdrAllocator` (user-supplied allocator for strings/sequences). Done.**
  `zidl_cdr_read_string`/`read_wstring` and the C backend's generated inline sequence-buffer
  allocation used `malloc` directly; `defaultValueToC`'s `@default("...")` string handling
  used `strdup`. All now route through `zidl_cdr_alloc`/`zidl_cdr_free`/`zidl_cdr_strdup`/
  `zidl_cdr_free_str`/`zidl_cdr_free_wstr` (`packages/zidl-cdr`), which fall back to
  libc malloc/free/strdup unless a `ZidlAllocator` (the same shared vtable struct from Phase
  0/1, `zidl_allocator.h`) is registered via `zidl_cdr_set_allocator()`.

  **Design decision, not just an implementation detail**: the registered allocator is
  **process-wide**, not per-`ZidlCdrReader`-instance as originally sketched. A decoded
  string/sequence field is freed later by a generated `_free()`-adjacent function
  (`zidl_cdr_free_str`/`_free_wstr`/`_free` call sites the C backend emits) that has no
  reader or other per-call context in scope — there's nowhere to remember "which allocator
  made this" without growing every generated struct with an extra field (an ABI break) or
  breaking every `_free()` call site's signature. A single global, set once at startup
  (mirroring e.g. SQLite's `sqlite3_config(SQLITE_CONFIG_MALLOC, ...)`), avoids both. The
  real limitation this accepts: two different topic types (or two participants) can't have
  two different CDR-layer allocators — only one process-wide default. `zidl_cdr_free_str`/
  `_free_wstr` reconstruct the original allocation size (`strlen(s)+1` / scan-to-NUL-wchar)
  since a bare `char*`/`uint16_t*` field has nowhere to remember it; sequence frees use the
  already-stored `_maximum * sizeof(elem)`, no reconstruction needed. A fixed 8-byte
  alignment is requested for every `zidl_cdr_alloc` call — provably sufficient for any IDL
  primitive or struct (C99 target, no `_Alignof`, and no per-element-type alignment plumbed
  through generated code).

  Verified: `zig build test`/`integration-test` (including two `check-goldens` fixtures
  updated to the new call sites), new `zidl-cdr` tests covering the allocator API directly,
  and — separately, not just compiled — a standalone C program using the real generated
  `Sample_deserialize` (a struct with both an unbounded `string` and an unbounded
  `sequence<long>` field) decoded a real CDR payload with a custom allocator registered:
  2 allocations, 2 frees, both fields correctly populated.
- **C++ backend: `_getOrCreate`/`zzdds_cpp.hpp` allocator support. Done.** Entity wrapper
  construction (`_getOrCreate`, this session's identity-cache work above) and zzdds's
  hand-written factory bookkeeping (`wrapFactoryHandle`/`DomainParticipantFactorySupport`)
  both hardcoded `std::make_shared`/global `new`. Landed as `std::pmr`-based, process-wide
  registration via a new `zidl::setCppAllocator(const ZidlAllocator*)` (new
  `zidl_allocator_pmr.hpp` in `zidl-cdr` — same `ZidlAllocator*` ABI as the C-side work
  above, bridged into a `std::pmr::memory_resource`). Both surfaces now use
  `std::allocate_shared` against `std::pmr::get_default_resource()`; `_getOrCreate`'s
  generation is gated on the existing pre-scan pass so the extra includes/machinery are only
  emitted where an entity is actually wrapped somewhere. Per the C++ `Allocator` named
  requirement, OOM signals via `std::bad_alloc` rather than a graceful null return — a
  deliberate, documented departure from every other allocator surface's contract, chosen
  over a non-throwing alternative for idiomatic-C++ ergonomics (degrades to
  `std::terminate()` under `-fno-exceptions`, matching libstdc++'s own `operator new`); the
  registration surface was deliberately kept as `ZidlAllocator*` rather than a raw
  `std::pmr::memory_resource*` so a future graceful/non-throwing option stays cheap to add
  later without an API break.

  **Correctness fix post-review (Greptile, PR #28, P1)**: the first cut of
  `ZidlAllocatorResource` read the active `ZidlAllocator*` from a mutable global slot
  *dynamically*, at both allocate- and deallocate-time, so that re-registering with a
  different `ZidlAllocator*` would take effect immediately — but that meant an
  already-outstanding object, allocated under allocator A, would have its eventual free
  routed through whichever allocator was *currently* registered (B) when its `shared_ptr`
  control block finally hit zero — silent heap corruption for any allocator that validates
  ownership on free (pool allocators, bounds-checkers). Fixed by binding each
  `ZidlAllocatorResource` permanently to one `ZidlAllocator*` at construction instead of a
  shared mutable slot: `setCppAllocator` now allocates a small new resource instance per
  registration (deliberately never freed — re-registration is a rare, startup/admin-time
  operation) and installs it as the process-wide default. Since
  `std::pmr::polymorphic_allocator` captures a `memory_resource*` by value at allocation
  time, every object now keeps freeing through the exact resource — and hence the exact
  `ZidlAllocator*` — that allocated it, for its whole lifetime, regardless of later
  re-registration. New allocations still pick up a re-registered allocator immediately, as
  originally advertised; what changed is that outstanding objects are no longer affected by
  it. Verified via a standalone regression test (allocate under A, re-register B, free the
  object allocated under A, assert A's `free` — not B's — is called): confirmed it fails
  under the old dynamic-slot code and passes under the fix.

  Verified end-to-end: real rebuild of zzdds against a local zidl checkout,
  `dcps_impl.cpp`/`zzdds_impl.cpp` compiled clean with real g++, and a standalone C++
  program (`zzdds::create_factory()` + `create_participant(...)`) proving construction
  routes through a registered tracking `ZidlAllocator`, re-registration takes effect
  immediately for new allocations, and `nullptr` restores the libc/`new`/`delete` default —
  see zzdds's `docs/design/allocator-strategy.md` "Phase 3" for the fuller writeup,
  including a note on why the identity-cache's control-block memory isn't asserted to free
  promptly (a pre-existing property of the `weak_ptr` cache, independent of this phase).

  **Follow-up (Greptile, PR #28, post-5/5 "worth a second read" note) + user-driven scoping
  question**: `setCppAllocator`'s own bookkeeping (installing one `ZidlAllocatorResource` per
  registration) used plain `new` unconditionally — the one spot in this header not already
  routed through a caller-supplied `ZidlAllocator` (factory bootstrap and
  `_getOrCreate`/`wrapFactoryHandle` both already are, via `zzdds_create_factory_with_allocator`
  and `setCppAllocator` respectively). For a toolchain with a working heap this is an accepted,
  bounded, one-time/startup-only allocation — but for a genuinely heap-free bare-metal target it
  would be the only remaining gap. Added an opt-in escape hatch: defining
  `ZIDL_ALLOCATOR_PMR_STATIC_POOL_SIZE` (an integer) before including the header switches
  `setCppAllocator` to placement-new into a fixed-size static pool instead of the heap — bounded,
  not wraparound-reused (reusing a slot behind a still-outstanding object would resurrect the
  wrong-allocator-freed bug the construction-time-binding fix above closed), asserting if the
  bound is exceeded. Default behavior (plain `new`) is unchanged unless the macro is defined.
  This isn't a zidl backend/codegen flag — `zidl_allocator_pmr.hpp` is hand-written and
  header-only, not generated per-IDL-spec, so a preprocessor macro the consumer defines in their
  own build is the natural, toolchain-agnostic switch; no codegen (`cpp.zig`) changes were
  needed. Verified: default mode still calls global `operator new` (confirmed via an
  abort-on-call override, so the check is meaningful, not vacuous); pool mode never calls global
  `operator new`/`delete` at all, for both `setCppAllocator` itself and the subsequent
  `_getOrCreate`-style `allocate_shared` call through it (confirmed the same way); exceeding the
  pool bound asserts rather than silently wrapping around onto a live slot. The first two are
  now permanent, CI-checked integration tests
  (`test/integration/cpp/test_allocator_pmr_static_pool.cpp`); the bound-exceeded check was
  verified manually (an abort doesn't fit the existing "compile, run, expect exit 0"
  integration-test harness without adding subprocess-based death-test infrastructure, judged
  disproportionate for a defensive bound on a rare, non-hot-path admin operation).

  **Correctness fix (Greptile, PR #28)**: the bound check was originally `assert()`-only —
  which compiles to nothing under `-DNDEBUG`, the normal production/release build
  configuration for the embedded targets this macro exists for. That meant in exactly the
  deployment mode that matters, exceeding the pool bound wouldn't abort — `pool[next++]`
  would silently index past the static array and placement-new construct a
  `ZidlAllocatorResource` into whatever static/global storage happened to follow it in the
  binary's layout. Confirmed this concretely (not just by inspection): computed the returned
  pointer for a deliberate over-bound call and showed it landed exactly
  `sizeof(ZidlAllocatorResource)` bytes past the last valid slot — a real out-of-bounds
  pointer, not a hypothetical. (AddressSanitizer did not flag this specific case, due to a
  known ASan blind spot around function-local statics inside `inline`-linkage functions,
  which get COMDAT-folded across translation units — the direct pointer-arithmetic proof
  stood in for it.) Fixed by adding an unconditional `if (next >= kPoolSize) std::abort();`
  right after the (now debug-only-diagnostic) `assert()`, so release builds fail loudly
  instead of corrupting memory. Verified the fix aborts correctly under `-DNDEBUG` (where it
  previously didn't).

  Net effect: with a caller-supplied static-pool-backed `ZidlAllocator` registered via both
  `zzdds_create_factory_with_allocator` and `setCppAllocator` (in pool mode), the *entire* C++
  allocation chain — factory bootstrap, everything the factory creates, and now
  `setCppAllocator`'s own registration bookkeeping — can avoid libc `malloc`/global `operator
  new` for the whole process lifetime, not just after some setup phase. That matters for the
  planned showcase apps' `LD_PRELOAD` verification shim (see below): a from-process-start
  abort-on-any-`malloc`/`new` shim becomes viable for a fully-configured app, rather than needing
  a "only trip after setup completes" leniency window.
- **C++ backend: `--cpp-pmr-containers` flag — STL-container allocator injection. Done.**
  The remaining allocator-injection gap after the above: generated `sequence<T>`/`string`/
  `wstring`/`map<K,V>` fields (struct members, union case payloads, CDR-source local
  temporaries) were hardcoded to `std::vector`/`std::string`/`std::wstring`/`std::map`,
  regardless of any `ZidlAllocator` registered elsewhere. Landed as a new opt-in backend
  flag (`--cpp-pmr-containers`, off by default) that switches all of these to their
  `std::pmr::` equivalents across all four C++ generator structs (`Generator`,
  `CdrGenerator`, `ConcreteImplGenerator`, `ImplGenerator`) plus the shared `cppTypeStr`
  helper, and emits `#include <memory_resource>` alongside the existing `<vector>`/
  `<string>` includes when set. Reuses Phase 3's `zidl::setCppAllocator`/process-wide
  `std::pmr` default resource directly — no new registration API, no per-instance
  scoped-allocator constructor plumbing, since `std::pmr::vector`/`string`/`map` all
  default-construct against `std::pmr::get_default_resource()` on their own. Applies
  uniformly to bounded and unbounded fields alike (only the allocator changes; existing
  bound-enforcement logic in the CDR read/write bodies is untouched). Off by default since
  it changes the concrete C++ type of every affected field — a real source/ABI break for
  any consumer naming `std::vector<T>`/`std::string` directly.

  Considered and rejected two alternatives (see zzdds's `docs/design/allocator-strategy.md`
  "the C++ template problem" for the fuller writeup): threading an allocator template
  parameter through every generated type (cascades through every interface signature,
  forces today's separately-compiled impl model into header-only templates — largest blast
  radius by far); and giving *bounded* fields a genuinely fixed-capacity, non-heap-allocating
  type mirroring `zidl_rt.BoundedArray` (dropped — the actual goal is caller-controlled
  allocation, not literally zero allocation, and a real `std::vector`/`std::string`-compatible
  bounded container satisfying the OMG C++11 PSM's requirements (formal-24-07-01 §6.10/§6.12)
  would have been a genuine from-scratch STL-container implementation, not a cheap wrapper).

  Verified: three new `zig build test` unit tests (flag off leaves output unchanged; flag on
  emits `std::pmr::` types + the include, for both bounded and unbounded fields; union-case
  CDR-decode locals also switch) — confirmed meaningful by breaking one assertion and
  watching it fail before restoring it. Plus a real, CI-tracked `zig build integration-test`
  addition: generates a fresh (non-golden) `types.hpp` from the shared
  `test/golden/types.idl` with the flag on, compiles it for real, and proves struct-field
  construction/assignment/destruction routes through a registered tracking `ZidlAllocator`
  (matched alloc/free counts) while defaulting to untracked `new`/libc when unregistered.
  Also manually confirmed (real compile, not just the unit tests) that a CDR
  serialize/deserialize roundtrip through `std::pmr::` struct fields works correctly. Along
  the way, confirmed a *pre-existing, flag-independent* gap while testing a union with a
  sequence/string case payload: it fails to compile with or without this flag, matching
  `cpp.zig`'s own documented limitation ("Unions with members of non-trivially-constructible
  types (std::string, std::vector, …) produce C++ that requires explicit
  constructor/destructor; not generated here") — not a regression introduced here, and out
  of scope for this flag.

  **Correctness fix (Greptile, PR #29, P1)**: the first cut only updated *type declarations*
  (struct/union member types, CDR locals, function signatures) to `std::pmr::string` under
  the flag, but missed the *value-construction* expressions in the generated interface
  adapters — `ConcreteImplGenerator`'s `str_ret` operation/attribute-getter bodies and
  `emitFieldAdaptOut`'s string-field assignment, plus `ImplGenerator`'s equivalent
  string-returning operation/attribute bodies — which still hardcoded
  `std::string(raw_c_string)`. This is worse than a stray extra allocation: confirmed via a
  real, minimal standalone compile that `std::pmr::string` has no implicit conversion from
  `std::string`, so any interface with a string-returning operation or attribute (or a
  string-typed out-adapted field) failed to *compile at all* under the flag — not merely
  bypassed the registered allocator, as originally suspected. Fixed by routing all five
  construction sites through the same `stringTypeName(opts)` helper the type declarations
  already use. Verified: 4 new unit tests (both generators, flag on/off) — confirmed
  meaningful the same way (break one, watch it fail, restore); a real generated
  (non-golden) interface with a string-returning operation/attribute now compiles clean
  under `--generate-interfaces --cpp-pmr-containers` where it previously failed to compile;
  and a linked, run standalone program proved both the returned values are correct and
  allocation for them routes through a registered tracking `ZidlAllocator` (matched
  alloc/free counts).
- **C backend: `{Type}_free()` is declared but never given a body. Done.** Found while
  verifying `ZidlCdrAllocator` above, not by looking for it: generated headers declared
  `void {Type}_free({Type} *v);` for structs with an unbounded sequence field
  (`src/backend/c.zig` — search for the two `"{s}{s}void {s}_free({s} *v);\n\n"` declaration
  sites), but no generator function anywhere emitted a matching definition — confirmed
  against the golden fixtures and via a real build; calling it was a link error. The only
  "free" logic that existed (`emitFreeKeyField`/`emitFreeArrayElements`/`emitFreeSeqElements`)
  was reachable *only* from `{Type}_compute_key_hash_from_cdr`'s cleanup path, for `@key`
  fields of a temporary decode — not a general free of every heap-owned field.

  Investigating turned up two more silent gaps beyond "declared but bodyless": the
  declaration gate itself (`structHasSequenceFields`) only checked for *unbounded* sequence
  fields, so (1) a struct with only an unbounded `string`/`wstring` field (no sequence at
  all) got no `_free()` declared, and (2) a struct with only a *bounded* `sequence<T,N>`
  field also got nothing declared — bounded sequences are still `{_maximum, _length,
  T*_buffer, _release}` in the C mapping (only `_maximum` is capped; `_buffer` stays a heap
  pointer, unlike bounded strings which get a genuine inline `char[N+1]`), confirmed by
  generating one and inspecting the header. All three folded into one fix: widened the
  gating check to treat any unbounded string/wstring or *any* sequence (bound or not) as
  needing a free, matching `keyFieldAllocatesC`'s already-correct semantics for the
  pre-existing `@key`-only path (kept the function's existing name,
  `structHasSequenceFields`, for minimal churn despite it now covering more than sequences).

  Implemented the real body generator (`emitStructFree` +
  `emitFreeTypeRefGeneral`/`emitFreeArrayElementsGeneral`/`emitFreeSeqElementsGeneral`,
  modeled on the existing `emitDefault`/`emitApplyDefaults` pair): walks *every* member (not
  just `@key` ones), correctly skips absent `@optional` fields via the same `_present`
  bitmask check `emitApplyDefaults` uses, frees a struct's base class's heap-owned fields
  too, and recurses into nested structs by *calling* their own generated `_free()` rather
  than re-inlining their member walk — which also incidentally fixed a narrower pre-existing
  gap in the `@key`-only helpers (nested sequences-of-sequences-of-strings only freed one
  level deep; the new general version fully recurses). Routes every free through the Phase 2
  allocator-aware helpers (`zidl_cdr_free_str`/`_free_wstr`/`_free`), never raw `free()`.

  Verified: new/updated unit tests for all three gaps, golden fixtures regenerated and
  reviewed as a clean expected diff (`Frame`/`Beacon` gain a `_free`; `Sample`'s already-
  declared one gains its body), and — real, not just unit-tested — a standalone C program
  registering a tracking `ZidlAllocator`, decoding a real CDR payload into a `Sample`
  (string + sequence fields), calling the generated `Sample_free`, and confirming exact
  alloc/free count match (2/2) — no leaks, no double-frees, no under-frees. See zzdds's
  `docs/design/allocator-strategy.md` "Phase 5" for the fuller writeup.

  **Correctness fixes (Greptile, PR #30)**: three real, serious bugs, all in the new
  general free-function generator specifically (the pre-existing `@key`-only one doesn't
  share these exposures, since it only ever runs on values it just decoded itself):
  (1) sequences were freed without checking `_release` (the C mapping's non-owning/
  borrowed-view flag) — fixed by wrapping each sequence's free in
  `if (seq._release) { ... }`; confirmed a stack-backed non-owning sequence crashed with
  `free(): invalid size` before the fix, made zero free calls after. (2) nested sequences
  (`sequence<sequence<T>>`) reused the same loop-index name (`_fsi`) at every recursion
  level, so the inner declaration's own bound-check shadowed the outer loop's index,
  silently reading the wrong element's length — fixed by threading a shared `depth` counter
  (across both array and sequence recursion) so each level gets a distinct `_fai{depth}`/
  `_fsi{depth}` name; confirmed a `sequence<sequence<string>>` with differing inner lengths
  segfaulted before the fix, freed exactly the real allocation count after. (3) array
  typedefs (`typedef string NameList[N];`) were skipped entirely by the declaration gate
  regardless of element type — fixed by checking the element type unconditionally and
  teaching the free-body generator's typedef case to delegate to the array-loop helper when
  dimensioned. All three verified by mechanically reverting just that one fix in real
  generated output and re-running to reproduce the exact reported failure, before
  confirming the fix resolves it.
- ~~**C backend `--generate-interfaces` (opaque handles + free functions)**~~:
  **Implemented.** Entity interfaces emit opaque `typedef struct Foo_s *Foo;` handles
  and free function declarations matching the OMG C PSM binding and the idioms of
  major C DDS implementations (Cyclone DDS, RTI Connext C API). No struct layout is
  exposed in the public header. Listener interfaces remain plain C callback structs
  with a `void *listener_data` context pointer. The C++ backend's `ConcreteImplGenerator`
  was updated to match (null checks and null-handle literals now use the opaque
  pointer directly instead of a two-field struct literal).
- ~~**Zig backend `--zig-generate-c-api`**~~: **Implemented**, via uniform entity
  handle boxing (see "Entity handle ABI: heap-boxing" below for the design and
  the discarded intermediate designs that led to it). Every non-listener entity
  interface — regardless of how many real implementations it has — crosses the
  C-ABI boundary as a single opaque pointer to a `zidl_rt.EntityBox`, matching
  the C backend's handle one-for-one. See `docs/ecosystem.md` §"`--zig-generate-c-api`"
  for the generated-code shape.
- **C++ backend: entity-parameter `dynamic_cast` adaptation only tried one
  concrete class per interface — fixed. Done.** Found while re-verifying
  `zzdds-examples/cpp/custom-allocator` against a fresh local rebuild
  (2026-08-07): `create_datareader(std::shared_ptr<TopicDescription>, ...)`'s
  generated C-ABI adapter only tried `dynamic_cast<TopicDescriptionImpl*>` —
  the one concrete class `entityImplName()` maps `TopicDescription` to. But
  `DDS::Topic : Entity, TopicDescription` at the abstract interface level, so
  `std::shared_ptr<Topic>` converts implicitly to `std::shared_ptr<TopicDescription>`
  and compiles fine, while the *concrete* `TopicImpl` (or its
  `--cpp-impl-override` replacement) doesn't itself inherit from
  `TopicDescriptionImpl` — each concrete `DDS::*Impl` class implements exactly
  one interface's pure virtuals. The `dynamic_cast` failed at runtime and
  threw `std::invalid_argument`, forcing callers through a workaround
  (`dp->lookup_topicdescription(name)` first, to get a genuine
  `TopicDescriptionImpl`-backed object).

  zidl's IR already had everything needed (`Interface.bases`) — no IR changes
  required. New `collectBaseImplementors` (`src/backend/interface.zig`) walks
  every concrete (non-callback, non-base) interface's base chain once per
  codegen run and records it against every ancestor interface it transitively
  implements; `cpp.zig`'s entity-parameter adapter (the `entity_in` case)
  consults this to emit an extra `dynamic_cast` fallback clause per sibling
  concrete class, in addition to the existing single-class cast, before
  throwing. Composes with `--cpp-impl-override` automatically, since every
  sibling's impl name is still resolved through the same `entityImplName()`
  choke-point. `Topic`/`ContentFilteredTopic`/`MultiTopic` (all implementing
  `TopicDescription`) is the only multiple-inheritance case in
  `dcps.idl`/`zzdds.idl` today, but the fix is general — any interface with
  more than one concrete implementor benefits. Verified: two new regression
  tests (generic synthetic `Base`/`LeafA`/`LeafB` case, plus a single-implementor
  case confirming the plain single-cast form is unchanged); live-verified
  against real zzdds — the generated `SubscriberImpl::create_datareader`
  adapter now cascades `TopicDescriptionImpl` → `zzdds::detail::TopicSupport`
  (a `Topic`) → `ContentFilteredTopicImpl` → `MultiTopicImpl` — and by
  removing `cpp/custom-allocator`'s `lookup_topicdescription` workaround
  entirely (both normal and zero-allocation-guarded acceptance runs pass).

## ContentFilteredTopic filtering: `get_field_from_cdr` (all backends, Done)

Found 2026-08-07 while exercising `zzdds-examples`: `ContentFilteredTopic`
filtering never actually activated in *any* binding, silently — a `DataReader`
created against a `ContentFilteredTopic` received every sample regardless of
its filter expression, with no error anywhere. Root cause: zzdds's
`TypeSupport.get_field` callback (the hook CFT evaluation calls to pull a
named field's value out of a raw CDR payload) was never wired up by any
codegen backend — every generated `TypeSupport` registration passed a null/
absent `get_field` function, so zzdds's CFT evaluator had nothing to call and
silently passed every sample through (matching its own documented "an
evaluation error passes the sample through" semantics, which masked the gap
completely instead of surfacing it).

Fixed by adding `emitGetFieldFromCdr` to all four backends, each emitting the
shape `TypeSupport.get_field` expects
(`zzdds_get_field_from_cdr_fn`/`getFieldFromCdr`): `{c_name}_get_field_from_cdr`
(C, `c.zig`), a free function of the same name (C++, `cpp.zig`),
`<Type>.getFieldFromCdr` (Java, `java.zig`), and `getFieldFromCdr` as a decl
on the generated Zig struct (`zig.zig`). Always emitted, even for a struct
with no filterable members (then it just always returns false) — gated the
same way as the rest of `--generate-zzdds-wrappers`' output. Does a full
CDR deserialize (any simple-typed member, not just `@key` ones — a CFT filter
expression can reference any of them, and CDR isn't randomly addressable, so
a partial/selective parse isn't meaningfully simpler than a full one), reusing
the struct's own generated `_deserialize`/`_free` rather than hand-rolling a
member walk. A matched string member's bytes are copied into a caller-supplied
scratch buffer rather than returned as a pointer into the deserialized value,
since that value is freed before the function returns; a string too long for
the scratch buffer leaves the field unmatched rather than truncating and
risking a wrong comparison result.

Also fixed along the way: the Java backend's bare named `sequence<T>`
operation params (`StringSeq`, `InstanceHandleSeq`, …) were stubbed to
`UnsupportedOperationException` — needed real JNI marshaling for
`register_type_support`'s `get_field_from_cdr` parameter to actually be
callable from Java. Verified end-to-end: zzdds core wiring +
`TypeSupport.get_field` invocation, all four zidl backends' generated code,
all four `zzdds-examples/*/shape` ports, and `dds-rtps/srcZig/shape_main.zig`
all updated and live-verified with a real CFT filter expression actually
suppressing non-matching samples (previously silently delivered).

## Entity handle ABI: heap-boxing (Implemented, zidl side)

Every non-listener entity interface gets a single opaque C-ABI pointer, always,
matching the OMG PSM idiom with no exceptions — no leaf/base distinction
anywhere in generated code. The pointer targets a small heap-allocated box
(`zidl_rt.EntityBox`) holding the native Zig `{ptr, vtable}` pair; boxing/
unboxing happens only at the `--zig-generate-c-api` export boundary, never in
Zig-native code, so pure-Zig consumers of zidl-generated interfaces pay nothing
extra and keep the fat-pointer type as-is (see the "idiomatic Zig" discussion
in the PR history that led here).

This design went through two discarded intermediate steps worth recording so
they aren't re-attempted:
1. A **hybrid leaf/base split** (devirtualize "leaf" interfaces to a bare
   pointer dispatched through an externally-supplied vtable symbol, keep
   "base" interfaces — `Entity`, `TopicDescription` — as the old fat-pointer
   struct) was implemented, then discarded. It required a new `--c-api-impl`
   mapping (a permanent per-interface maintenance burden), left base
   interfaces non-opaque in the C header, baked "this interface has exactly
   one implementation, forever" into the wire format, and — critically — had
   a real correctness bug: devirtualized dispatch assumed a statically-known
   vtable, discarding whatever vtable a native call actually returned, so a
   failed `create_*` call's nil-object result would misdispatch on any
   subsequent call.
2. A **naive "always box fresh" design** (every export call allocates a new
   box, unconditionally) was also discarded: it breaks handle identity for
   accessor operations (`get_participant()` called twice would return two
   different, non-`==`-comparable boxes) and leaks unconditionally for
   widened-view accessors (`get_entity()`, `lookup_topicdescription()`), since
   the live C++ `ConcreteImplGenerator`'s Impl-class destructor is `= default`
   and nothing else in the generated code frees a box.

The design that replaced both: every entity interface's vtable gains one
synthetic slot, `get_c_abi_handle: *const fn(*anyopaque) *anyopaque`, alongside
the existing `deinit`. Generated code is completely uniform —
`return _r.vtable.get_c_abi_handle(_r.ptr);` for every entity return, no
allocation and no allocator lookup in generated code at all. How the handle is
produced is entirely the concrete implementation's choice, not zidl's:

- **Recommended pattern (zzdds side, not yet done — see below)**: cache and
  reuse a handle across repeated calls to the same object (lazily created on
  first request, stored on the concrete impl, freed in that object's own
  `deinit()`). This fixes both discarded designs' problems at once — identity
  is preserved, and nothing leaks — with no new C-ABI release step (preserving
  familiarity with Cyclone/Connext-style APIs) and no new IDL annotation.
- Allocation, when needed, uses whatever allocator the concrete impl already
  has (e.g. `self.alloc`) — ordinary access, not a new generic vtable-mediated
  mechanism. This is "Tier 1" of the allocator-control work; see the zzdds
  roadmap's Tier 1 entry for what's left to do there, and Tier 2/3 for the
  separate data-plane and per-entity-kind allocator work.

**zzdds-side follow-up**: every hand-written concrete impl needs a
`get_c_abi_handle` implementation following the cache-and-reuse pattern above
(including for widened views it returns, e.g. `StatusConditionImpl` caching
its own `entity_view_handle` for `get_entity()`). Done — this vtable slot has
shipped in tagged zidl releases since `v0.2.7-zig.0.16.0`; see the zzdds
roadmap for the implementation details.

### C++ backend: entity wrapper identity (Implemented)

A related but independent gap, found while auditing whether this design should
change anything for the C++ backend (it doesn't need to — C++'s own
`class Foo` / `class FooImpl : public Foo` abstract-class hierarchy already
gets real polymorphism natively from the compiler-embedded vtable, which is
exactly what the Zig side had to hand-roll as a fat pointer; there's no
analogous "narrow a fat reference into an opaque C handle" problem on the C++
side for boxing to solve). But looking at `ConcreteImplGenerator`
(`src/backend/cpp.zig`) surfaced a structurally similar, pre-existing gap: it
constructed a fresh `std::make_shared<FooImpl>(_h)` on every operation that
returns an entity, so calling e.g. `participant->get_topic("X")` twice used to
return two different `FooImpl` objects wrapping the same underlying `_h` —
not identity-equal, though not a leak either (`shared_ptr` RAII cleaned up
correctly regardless of how many wrapper instances existed).

This wasn't practically fixable before the heap-boxing work above: nothing
guaranteed the raw C handle `_h` was itself stable/reusable across calls, so
there'd have been no correct value to key a wrapper cache against. Now that
`get_c_abi_handle` makes the underlying handle identity-stable, the C++ side
reuses the same principle. Every entity `FooImpl` class gets a `public static
std::shared_ptr<FooImpl> _getOrCreate(DDS_Foo h)` factory (declared in the
header next to the constructor, defined once in the generated `.cpp`), backed
by a function-local `static std::unordered_map<DDS_Foo, std::weak_ptr<FooImpl>>`
plus a `static std::mutex` — C++11 "magic statics" give this exactly one
instance per class, lazily initialized, thread-safe, with no separate member
fields or manual initialization needed. Lookup: if a live (non-expired)
`weak_ptr` is cached for the handle, return `.lock()`'s result; otherwise
construct-and-cache a new `FooImpl` and return it. `_getOrCreate(nullptr)`
returns `nullptr` (subsuming the old separate `if (!_h) return nullptr;`
guard at each call site). All four generated call sites that used to construct
a wrapper directly — the entity-returning operation path, the entity
attribute getter, the sequence-of-entities out-adaptation loop, and the
listener-trampoline argument wrapper — now route through `_getOrCreate`
instead of `std::make_shared` directly, so identity holds everywhere a wrapper
can originate, including entities arriving via a listener callback.

One accepted tradeoff: expired (`weak_ptr` no longer lockable) entries are
only overwritten lazily, on the next `_getOrCreate` call for that same handle
value — there's no active sweep, so a long-running process that creates and
destroys many distinct entities whose C handle addresses are never reused
will accumulate dead map slots (small, pointer-sized; not a use-after-free or
object leak, since the cache only ever holds a `weak_ptr`). Not addressed
here; revisit if it matters in practice.

Unlike the Zig-side `get_c_abi_handle` item, this needed no hand-written zzdds
participation — zzdds doesn't author its own C++ bindings; they're entirely
generated via `--cpp-generate-impl`. Verified two ways: (1) the codegen unit
tests in `src/backend/cpp.zig` assert the header declaration, the cache/mutex
body, and all four call sites; (2) real-world check against zzdds — pointed
`zzdds/build.zig.zon` at this local zidl checkout, ran
`zig build install -Dcpp-binding=true`, and compiled the resulting
`dcps_impl.cpp` (95 `_getOrCreate` occurrences across ~35 entity classes) with
`g++ -std=c++17 -Wall -Wextra -pthread` — zero errors, zero warnings
attributable to the new code (12 pre-existing, unrelated sign-compare
warnings only). A standalone reproduction of the exact generated pattern
(separately compiled and run) confirmed the runtime invariants: two calls for
the same live handle return the identical `shared_ptr`; a different handle
gets a distinct wrapper; dropping every `shared_ptr` for a handle lets the
cached `weak_ptr` expire so the next call constructs fresh rather than
returning a dangling reference; and a reused handle address correctly
overwrites the stale slot. Not yet in a tagged zidl release — needs a
release before zzdds's C++ users see it (zzdds currently pins
`v0.2.9-zig.0.16.0`, unaffected until the pin is bumped).

### Zig backend: `as_{Base}` upcast vtable slot (Implemented)

zzdds hand-wrote ~12 free functions upcasting an entity handle to an
IDL-declared base interface across the C-ABI (`DDS_Topic_as_DDS_Entity`,
`DDS_GuardCondition_as_DDS_Condition`, ...), each with its own
vtable-identity check. Every one of these relationships is already declared
as IDL interface inheritance, so this is now generated: `emitInterface`
(`src/backend/zig.zig`) adds one synthetic `as_{Base}: *const fn(*anyopaque)
{Base}` slot per direct declared base, alongside `deinit`/`get_c_abi_handle`
(unconditional, same precedent); under `--zig-generate-c-api`,
`emitCApiExports` additionally emits a `{Iface}_as_{Base}` export wrapper per
base, unboxing self, calling the native slot, boxing the result via the
target's own `get_c_abi_handle`.

Two designs that don't work, ruled out during investigation:
- **Raw pointer reinterpretation** (`@ptrCast` the derived vtable as the
  base's `Vtable` type) only works for whichever base is declared *first* —
  `collectInterfaceMembers` flattens inherited ops bases-first, so a second
  (or later) base's fields start at a non-zero offset; reinterpreting would
  silently misread the wrong fields. Confirmed via a dedicated golden/unit
  test fixture with a non-first base.
- **A permanent external mapping** (as `--c-api-impl` would have been) bakes
  in "there is exactly one implementation," the same problem that dropped
  that design originally.

**Formatting bug found and fixed (2026-08-13): `zig build regen-goldens` and `zig fmt .`
were fighting each other.** The ergonomic `pub fn as_{Base}(...)` convenience method
(`emitInterface`) ended every method with a trailing blank line, matching the existing
ops/attrs style above it — safe there only because `deinit` (single-newline close, no
trailing blank) always followed and absorbed it. This loop can itself be the last thing in
the struct body (any interface with no nested `type_decls`/consts), so its own trailing
blank line landed directly before the closing `};` in that case — `zig fmt` strips a blank
line immediately before a closing brace, so every `regen-goldens` run produced output `zig
fmt` immediately wanted to re-edit. Fixed by moving the separator to *before* each method
instead of after (mirrors `deinit`'s own no-trailing-blank close, since this loop is now in
the same "might be last" position `deinit` already had to account for). Verified by
actually reproducing the fight (not just reasoning about it): `regen-goldens` then `zig fmt
.` back-to-back, confirming zero further changes on the second pass. Also ran a plain `zig
fmt .` across the repo while here — unrelated hand-formatting drift in `src/backend/
java.zig` (a multi-line format-args tuple `zig fmt` wanted to column-align) that had simply
never been run through the formatter after being written.

The vtable slot is the mechanism that generalizes correctly: the concrete
implementation supplies `as_{Base}`, and dispatch through the vtable is
correct by construction — no runtime "is this really the vtable I expect"
check is needed or possible to bypass, unlike the hand-written functions it
replaces.

**zzdds migration note**: `zzdds.idl`'s own vendor-extension interfaces
declare real IDL bases too (`interface Topic : DDS::Topic`), which was easy
to miss — the upcast direction of the `ZZDDS.* ↔ DDS.*` conversions
(`zzdds_Topic_as_DDS_Topic` etc.) is *also* now generated, not just the
DDS-internal ones. Only the downcast direction (`DDS_Topic_as_zzdds_Topic`,
requiring a runtime vtable-identity check IDL can't express) remains
hand-written.

### All backends (annotation support)

- **`@verbatim` injection**: `@verbatim` annotations are parsed and preserved in the IR
  as `RawAnnotation` entries, but no backend currently reads or acts on them. The
  intended behaviour is to inject the annotation's `text` at the placement point
  (`BEGIN_FILE`, `BEFORE_DECLARATION`, etc.) when the `language` field matches the
  backend's language id or `"*"`. See `docs/backend_interface.md` for the planned
  pattern.

### Zig backend

- **`--zig-generate-c-api` bare `sequence<EntityInterface>` operation params —
  binary layout corruption, fixed. Done.** Surfaced 2026-08-07 while
  live-verifying a same-participant discovery fix in zzdds: Java's
  `Subscriber.get_datareaders()` returned a real, correctly-counted
  `DataReader`, but *any* native call on it crashed with SIGSEGV. Not a
  Java-specific bug (two initial theories pointing at Java-side boxing were
  both wrong) — a core C-ABI layout mismatch affecting every binding equally,
  just never triggered before this was the first real caller of a bare
  `sequence<EntityInterface>` operation (`get_datareaders`/`WaitSet.wait`/
  `get_conditions`) through the generated C ABI. For a typedef like
  `DataReaderSeq`, the C backend's header declares single-opaque-pointer
  elements (8 bytes), but `--zig-generate-c-api`'s exported function reused
  its own native extern struct — full `{ptr, vtable}` fat-pointer elements
  (16 bytes) — directly as the parameter type, with zero boxing. Matches a
  TODO this backend had already flagged for sequences generally; entity
  elements were the one case that had never been reached, since scalar/string
  sequences never had a size mismatch to expose it.

  Fixed: new `typeRefIsEntitySequence` detects a bare `sequence<EntityInterface>`
  typedef; `emitCApiOp` now reinterprets the caller's buffer as the real C-ABI
  shape, calls the vtable through a native-shaped temporary, and boxes each
  result element individually via the same `.vtable.get_c_abi_handle(.ptr)`
  convention used everywhere else for entity returns. Also fixed a
  control-flow bug this surfaced: non-void/non-entity-returning operations
  used to inline `return _self.vtable.foo(...)` directly, making the new
  post-call boxing code unreachable — fixed by capturing the return value and
  returning it after boxing. Generic, not Java-specific — C/C++/Zig get the
  fix for free too (once a `WaitSet`/`GuardCondition` C-ABI constructor exists
  to actually exercise `WaitSet.wait()`/`get_conditions()` end-to-end; that
  gap is tracked separately, in zzdds's own roadmap). Verified: one new
  regression test asserting the exact generated-code shape, plus zzdds's real
  C++ `test-bindings` smoke test and full test suite; live-verified
  `create_readcondition()` on a `get_datareaders()`-returned reader now
  succeeds (previously a guaranteed SIGSEGV).

- **`computeKeyHashFromCdr` (per topic struct) — Done, and a real live leak fixed along
  the way.** Found while reviewing zzdds-examples' `hello_world` for rough edges
  (2026-08-06): the Zig backend generated `computeKeyHash(value: @This())` (works on an
  already-deserialized value) but never the C/C++ backends' equivalent
  `{Type}_compute_key_hash_from_cdr(payload, len, hash_out)` — a function matching
  zzdds's `TypeSupport.compute_key_hash` callback shape exactly
  (`fn(ctx: *anyopaque, payload: []const u8) [16]u8`), so generated code can be passed
  directly to a TypeSupport registration call without hand-written CDR-deserialize-then-
  hash glue. Added `emitComputeKeyHashFromCdr` (`zig.zig`), gated the same way
  `computeKeyHash` already is (`--generate-zzdds-wrappers` and `isZzddsTopicStruct`).

  Unlike the C backend (whose generated function resolves its allocator from a global,
  process-wide override — `zidl_cdr_set_allocator` — defaulting to malloc/free), this
  stays consistent with the rest of the Zig runtime's explicit-allocator idiom instead of
  importing C's global-state pattern: `ctx` is a `*const std.mem.Allocator`, supplied by
  the caller at registration time via `TypeSupport.ctx`, used only for variable-length
  `@key` fields. Keyless structs never dereference it, matching `TypeSupport.ctx`'s
  existing "Zig-native implementations that need no state may pass `undefined`" contract.

  **Found a real, live bug while verifying, not by looking for one**: an early version
  leaked on every call for a keyed struct with any variable-length key field (string or
  unbounded sequence) — `deserializeKey` heap-allocates such fields, and nothing freed the
  resulting temporary value. Root cause traced deeper than this one function: zidl's Zig
  backend's `deinit()`/`clone()` generation (`structNeedsCleanup`/`typeRefNeedsSeqDeinit`)
  only ever counted unbounded *sequences* as needing cleanup, never plain unbounded
  `string`/`wstring` fields outside `--zig-generate-toml-config` — a narrower version of a
  bug already found and fixed for the C backend (see "C backend: `{Type}_free()` is
  declared but never given a body" below), just never ported to Zig. Confirmed *live*, not
  hypothetical: zzdds's own `dcps.idl` has `TopicBuiltinTopicData`/
  `PublicationBuiltinTopicData`/`SubscriptionBuiltinTopicData`, each with plain unbounded
  `string name`/`type_name`/`topic_name` fields that `deinit()` silently never freed.

  **Widened the gate (new `memberNeedsCleanup`, replacing `typeRefNeedsCleanup`) to match
  the C backend's parity — with one exclusion the C fix didn't need to consider.** C's
  runtime `_default()` always calls `zidl_cdr_strdup` unconditionally, so by the time
  `_free()` could ever run, a string field is *always* a genuine heap pointer, never a raw
  literal — freeing it unconditionally is always safe. Zig's comptime struct-literal field
  defaults can't do the equivalent at compile time: a member with an explicit non-empty
  `@default("...")` string, on a value that was default-constructed and never actually
  deserialized (a real, not just theoretical, scenario — e.g. an `errdefer`-triggered
  `deinit()` firing before that field was ever reached), is still pointing at static
  literal storage; `alloc.free()` on that is memory corruption, not a leak. Confirmed this
  isn't hypothetical either: `zzdds.idl` has several (`@default("default")`,
  `@default("239.255.0.1")`, ...). New `typeRefIsDirectPlainString`/
  `memberHasNonEmptyStringDefault` narrow the exclusion to exactly that shape — a member
  that is *itself* a plain unbounded string (or typedef chain to one) with a non-empty
  default, outside `--zig-generate-toml-config` (which is exempt: `emitFieldSeqCloneStmt`
  already dupes plain strings unconditionally regardless of that flag, and
  `_toml_applied` tracks real per-value ownership for exactly this case). Such a member is
  deliberately left out of cleanup outside that flag — a narrow, pre-existing gap, not a
  new regression — rather than risk freeing static memory.

  Verified past "compiles": new unit tests for the general case, the non-empty-default
  exclusion (and its empty-default and toml-config counterexamples), and golden fixtures
  regenerated and reviewed as a clean expected diff (`Sample`/`Frame`/`Beacon` gain real
  `deinit()`/`clone()` string handling). Real, not just unit-tested: a standalone Zig
  program serializing a keyed struct with a variable-length string key, then calling the
  generated `computeKeyHashFromCdr` on the raw bytes, confirmed the hash matches
  `computeKeyHash` on the original value with zero leaks (`std.testing.allocator`'s leak
  checker, clean). Against real zzdds: `TopicBuiltinTopicData.deinit()` now frees `name`/
  `type_name`; zzdds's own `zig build test`/`test-bindings` (Java smoke test,
  `cpp_allocator_smoke`) green with no regressions.

- **Union discriminant edge cases**: `wstring` and `fixed_pt` discriminant types emit a
  `// TODO: unsupported discriminant` comment in `serialize` / `deserialize` bodies.
- **Sequence element read with array-typedef element**: A rare edge case where a sequence
  element type resolves to an array typedef emits a `// TODO` comment in the deserialize
  path.

### Java backend

- **`getFieldFromCdr` was a `return null;` stub for a keyless topic under
  `--generate-zzdds-wrappers` — fixed. Done.** Found building zzdds-examples'
  `java/waitset` (2026-08-10), whose `WaitsetSample` type is deliberately
  keyless (matching `hello_world`'s own convention across every binding):
  `emitStructZzddsWrappers`'s keyless-topic branch (added when
  `--generate-zzdds-wrappers` was extended to keyless topics per DDS 1.4
  §2.2.2.1) only emitted the three methods that path's own author believed
  the wrapper codegen actually calls (`serializeKey`/`computeKeyHash`/
  `deserializeKey`) plus a hardcoded stub for `getFieldFromCdr` — but a
  filter expression (`ContentFilteredTopic` or `QueryCondition`) can
  reference any simple-typed member, not just `@key` ones, so this stub
  silently broke filtering for every keyless topic in Java specifically —
  the keyed-struct branch already called the real `emitGetFieldFromCdr`
  (added in the "ContentFilteredTopic filtering: `get_field_from_cdr`"
  round), just never extended to this one. The C and C++ backends don't
  have the equivalent bug: both call their own `emitGetFieldFromCdr`
  unconditionally, with no keyed/keyless branch at all.

  Confirmed via a real, minimal, targeted check (not just a golden-diff):
  serialized a real `WaitsetSample` value to CDR bytes by hand, called the
  pre-fix generated `getFieldFromCdr(payload, "priority")` directly (no DDS
  setup needed — it's a pure static function) and confirmed it returned
  `null` for a field that's genuinely present; regenerated after the fix and
  confirmed the same call now returns the correct boxed value (and still
  `null` for a field that really doesn't exist). Fixed by calling the
  existing `emitGetFieldFromCdr` from the keyless branch instead of emitting
  its own inline stub — no changes needed to `emitGetFieldFromCdr` itself,
  since `deserializeFrom` (which it calls) already exists unconditionally on
  every topic struct regardless of key status. New assertion added to the
  existing "`--generate-zzdds-wrappers` still emits DataWriter/DataReader
  for a keyless struct" test, checking for the real generated switch-case
  body rather than the stub. `zig build test` green (1008/1008).

- **`any` / `object` / `value_base` member access**: Emits a `// TODO: any/object`
  comment. These IDL constructs are rarely used in modern DDS profiles; implementation
  priority is low but they are not intentionally excluded.

### TypeObject encoder (Zig only)

- **`typedef` / alias TypeObjects**: The encoder emits a `TK_NONE` placeholder for all
  typedef and alias declarations.
- **`map<K,V>` and `fixed_pt` TypeObjects**: The encoder emits a `TK_NONE` placeholder
  for map key/value types and `fixed_pt` fields.
- **Generated `pub const type_object` for non-struct types**: The TypeObject encoder
  handles `enum`, `union`, `bitmask`, and `bitset`, but the Zig backend only emits
  a `pub const type_object` field inside `struct` declarations. The other four types
  need the same constant wired in.

### XRCE / MicroZig (step 1a)

- **Wire `test/xrce-microzig/` into `zig build integration-test`**: The fixture
  (`test/xrce-microzig/`) is committed and self-contained, but the main `build.zig`
  does not yet invoke it as part of `zig build integration-test`. Blocked on confirming
  the 0.15.1 toolchain path is available in CI.

---

## Recently Completed

| Item | Notes |
|---|---|
| Typed DataReader/DataWriter spec completeness: `_w_condition` family + other gaps (all backends) | Discovered while fixing an unrelated race in `zzdds-examples/zig/waitset`: `zig/waitset` was the only binding with a `take_w_condition`-equivalent (a hand-written Zig-native raw op), which is *why* it alone needed a two-step "query take, then plain take" split the other three bindings never had the option to hit the same race in. Auditing all four backends' `--generate-zzdds-wrappers` output against the DDS 1.4 spec's full `FooDataReader`/`FooDataWriter` implicit-IDL operation set (confirmed directly against the OMG spec text, not just `dcps.idl`'s own comment) found the entire `read_w_condition`/`take_w_condition`/`read_next_instance_w_condition`/`take_next_instance_w_condition` family missing from *every* backend, plus: batch `read_instance`/`take_instance` missing from C/C++/Java (Zig already had it); Java missing `get_key_value`/`lookup_instance` (reader *and* writer) and `register_instance`/`write_w_timestamp`/`dispose_w_timestamp`/`unregister_w_timestamp` entirely, not just the `_w_timestamp` variants; `register_instance_w_timestamp` missing everywhere. Fixed across all four backends, backed by new zzdds-side core (`DataReaderImpl.takeNextInstanceFiltered`/`readNextInstanceFiltered`, instance-selection itself respecting the condition per spec §2.2.2.5.3.18-19, not just "the next instance with any sample") and C-ABI (`zzdds_take/read_w_condition_raw`, `zzdds_take/read_next_instance_w_condition_raw`, `zzdds_take/read_n_instance_raw`) additions — see zzdds's own roadmap for that half. Java needed genuinely new JNI native methods (`ZzddsRuntime`/`zzdds_java_runtime.c`), not just codegen, since the underlying capability didn't exist there at all for several of these. All four `zzdds-examples/{zig,c,cpp,java}/waitset` subscribers updated to use the real generated `take_w_condition` uniformly (closing the originating race everywhere, not just in Zig, and giving every binding's example the same core-interaction shape) and verified via the full 8-pair cross-binding smoke test. **Explicitly out of scope at the time: loan variants** (`take_loaned_w_condition` etc., and extending `take_loaned`/`return_loan` to Zig/Java) — traced the then-current C/C++ loan API to a plain process-local heap allocation with no actual zero-copy/SHMEM behind it (SHMEM transport is explicitly "not planned for v1" elsewhere in this roadmap and zzdds's own), so building more surface area against that shape then risked throwaway work once real zero-copy design happens; recorded here rather than silently dropped. **Superseded 2026-08-22**: the "Raw / loaned DataReader & DataWriter codegen" entry above replaced the whole hand-written `take_loaned`/`return_loan` family (C/C++-only) with real `dcps.idl` loan ops generated uniformly across all four bindings including the `_w_condition`/`_instance` filtered variants — not more throwaway surface area against the old shape, a full replacement of it. |
| ContentFilteredTopic filtering: `get_field_from_cdr` (all backends) | Wires zzdds's `TypeSupport.get_field` hook, previously never emitted by any backend so CFT filtering silently never activated in any binding. See "ContentFilteredTopic filtering" above for the full writeup, including the Java bare-`sequence<T>`-param JNI marshaling fix it needed. |
| C++ backend: entity-parameter `dynamic_cast` now tries every sibling concrete implementor | New `collectBaseImplementors` (`interface.zig`) lets the C-ABI adapter for an interface with multiple concrete implementors (e.g. `TopicDescription`: `Topic`/`ContentFilteredTopic`/`MultiTopic`) try each one instead of just the single class `entityImplName()` maps by name — see "C and C++ backends" above for the full writeup. Removed `zzdds-examples/cpp/custom-allocator`'s `lookup_topicdescription` workaround. |
| `--zig-generate-c-api` bare `sequence<EntityInterface>` params: binary layout corruption fixed | Entity-sequence elements (`DataReaderSeq`, `ConditionSeq`, …) now boxed to the C ABI's single-opaque-pointer layout instead of passing the native 16-byte fat-pointer layout straight through — see "Zig backend" above for the full writeup. |
| Zig backend: `computeKeyHashFromCdr` + `deinit()`/`clone()` plain-unbounded-string parity | Generates the Zig-backend equivalent of C/C++/Java's `{Type}_compute_key_hash_from_cdr`, and along the way widened `deinit()`/`clone()` cleanup to cover plain unbounded `string`/`wstring` fields outside `--zig-generate-toml-config` (previously only unbounded sequences counted — a real, live leak in generated code, not just this new function; see "Zig backend" above for the full writeup, including the non-empty-`@default` exclusion this needed that the C-backend parity fix didn't). |
| C++ backend: `--cpp-impl-override`/`--cpp-impl-include` | Lets `--cpp-generate-impl`'s construction and `dynamic_cast` parameter-adaptation sites resolve a vendor-extended concrete class instead of the default abstract one, for entity interfaces. See "C and C++ backends" above for the full design and zzdds's own roadmap for the consumer side (four hand-written `*Support` classes, `build.zig` wiring, `cpp/hello_world`'s raw-C-ABI workaround removed). Not yet in a tagged release. |
| C backend: `--c-no-free` | Suppresses `{Type}_free()` (prototype and body) for a whole generation pass. Needed when a consumer compiles a generated `_cdr.c` into a binary that *already* exports `{Type}_free` for the same structs from elsewhere — confirmed as a real, not hypothetical, need: zzdds compiling its own `dcps_cdr.c` into `libzzdds.so` hit 25 duplicate-symbol link errors against its existing native `--zig-generate-c-api` `_free` exports before this existed. Deliberately scoped to `_free` only (not folded into `--no-typesupport`, which suppresses `serialize`/`deserialize`/`skip` too) — those three had no collision to avoid, confirmed by the fact that removing just `_free` from the mix cleared every error. See zzdds's `docs/roadmap.md` "Planned" for the consumer side (a second, `--c-no-free`-flagged generation pass feeding what's compiled into `libzzdds.so`, kept separate from the pass that produces the installed header, which must keep declaring `_free` since it's still real). |
| Java backend: real entity JNI bridge, QoS/status marshaling, listener upcalls, `--generate-zzdds-wrappers` | Previously the Java backend only got as far as generating `*Impl.java` + a `dcps_jni.c` that never linked (wrong `zidl_`-prefixed symbol names, structs/listeners passed by value where the real ABI takes pointers, entity params/returns naively C-cast between `jobject` and the opaque handle) and was never compiled, linked, or run by any test. Fixed: correct `{c_name}_{op}` symbol calls and pointer conventions matching `c.zig`; real entity box/unbox via `GetLongField`/`NewObject` with multi-hop `_as_<Base>` widening for entity interface views (`interfaceHasBaseTransitively`/`findConversionPath`); field-by-field QoS/status struct marshaling (`StructMarshalGenerator`, reusing the CDR emitter's field-shape dispatch); listener JNI upcall trampolines (cached `JavaVM*`, `AttachCurrentThreadAsDaemon` for zzdds's own network threads, boxed entity + status args); `--generate-zzdds-wrappers` Java support (typed DataWriter/DataReader + `computeKeyHashFromCdr`). Also fixed, found only via real cross-process runtime testing (not golden-diffing generated text) — a genuine `jstring`-handling bug: `string`/`wstring` params and returns were cast directly between `jstring` and `const char *` instead of going through `GetStringUTFChars`/`NewStringUTF`/`ReleaseStringUTFChars`. This produced garbage topic/type-name bytes that happened to read as *consistent* garbage within one JVM (interned string literals share one object, so both sides of an in-process test coincidentally "matched"), masking the bug in every same-process test; it only surfaced as silent DDS discovery-match failure between two separate JVM processes — traced by instrumenting the RTPS/SEDP receive path down to the decoded (garbage) topic/type-name strings. New: a compiled+linked entity JNI integration test in zidl's own `integration-test` step, and zzdds's `zzdds-java-example/` (two real JVM processes, real UDP RTPS discovery) plus a `test-bindings` Java smoke test. |
| `--zig-generate-toml-config` (Zig backend) | Emits `applyToml(alloc, table: anytype) !void` per struct, driven entirely by the IR (including the already-generic `@default` metadata and each enum's existing `_fromString` helper) — no new parser dependency, `table` is duck-typed. Built for `zzdds`'s config-file support (see its `docs/decisions.md` §Configuration); found and fixed a real pre-existing bug along the way: `clone()` was only ever emitted in the typesupport-enabled path, never under `--no-typesupport` (exactly what `zzdds`'s own vendor-config generation uses) — moved into the same `structNeedsSeqDeinit` gate as `deinit()`, since both are lifecycle operations independent of CDR/wire support. See `docs/backend_zig.md` §TOML config application. |
| C++ backend: four bugs found via zzdds's real (compile+link+run) C-ABI allocator-injection verification | None of these were caught before because nobody had compiled zzdds's own `zzdds_impl.cpp` (as opposed to `dcps_impl.cpp`, unaffected) with a real C++ compiler. **(1)** `native_handle()` override mismatch — cross-module entity `.bases` were reset to empty by the IR builder's import-fill (`resetNonCallbackInterfaces`, to avoid growing Zig vtables), making a real base (`DDS::DomainParticipant : Entity`) look base-less from a different file's generation pass; fixed by preserving `.bases` specifically while still resetting operations/attributes, plus making `collectEntityBaseNames` walk the base chain transitively (`src/ir/builder.zig`, `src/backend/interface.zig`). **(2)** Listener trampoline wrapping the wrong class for a cross-module `@callback interface`'s flattened-in entity parameter (bare class name resolved in the listener's own namespace instead of the parameter's actual module) — fixed by using the existing `entityImplName()` qualifier consistently. **(3)** A regression from this session's own `_getOrCreate` work: making it unconditional meant its `make_shared` body got compiled for entity classes intentionally left abstract (completed by a hand-written subclass elsewhere, e.g. zzdds's `DomainParticipantFactorySupport`); fixed with a pre-scan pass so `_getOrCreate` is only emitted for interfaces actually wrapped somewhere in the spec. **(4)** Scalar-typedef listener parameters (e.g. `typedef long InstanceHandle_t`) passed by pointer in the C++ trampoline while the C listener struct declared the same field by value — the C backend's `isCPrimitive` already resolves typedef chains correctly; added the equivalent `typeRefIsCScalar` to the C++ backend. All four verified via `zig build test` + `integration-test` plus a real `dcps_impl.cpp`/`zzdds_impl.cpp` recompile after each fix — see zzdds's `docs/design/allocator-strategy.md` for the full writeup. |
| C backend `--generate-interfaces`: opaque handles | Entity interfaces emit `typedef struct Foo_s *Foo;` instead of a fat-pointer vtable struct; C++ `ConcreteImplGenerator` null-checks/null-handle literals updated to match. |
| Const type-checking (semantic analyser) | `const_type_mismatch` diagnostic; validates initializer compatible with declared type (§7.4.3). PR #20. |
| Union discriminant type validation | `invalid_discriminant_type` diagnostic; validates integer/char/boolean/wchar/octet/enum base (§7.4.8), including typedef-of-typedef. PR #20. |
| C++ concrete impl backend: 11 TODO stub methods | `get_listener` ×6 (stash pattern), `get_offered/requested_incompatible_qos_status` ×2, `WaitSet::wait`/`get_conditions` ×2, `SubscriberImpl::get_datareaders` — unlocked by extending `isAdaptableSeqElemIn` for simple-struct and entity-interface sequence elements, plus a `listener_` stash member. |
| `--zig-generate-c-api` trivial forwarders (Zig backend) | Vtable slots are C-ABI; exports are one-liners. No type conversion. |
| `extern struct` for C-compatible IDL types | Structs whose fields are all C-compatible use `extern struct`; others use plain `struct`. |
| `deinit(alloc)` on sequence-containing types | Recursively frees heap-owned sequence buffers (`_release == true`). |
| `clone(alloc)` on sequence-containing types | Deep copy symmetric to `deinit`; used by vtable `init` to own QoS with sequence fields. |
| Cross-module `@callback interface` inheritance (IR builder) | An imported file's own AST was previously discarded after semantic analysis, so `ir.build()` only ever registered empty Pass-1 skeletons for imported types — fine for plain type references, but silently dropped the real member list needed to flatten a `@callback interface` inheriting a cross-module base. Fixed via `ir.buildWithImportedUnits`/`ImportedUnit`, which additionally fills imported units' own skeletons from their own AST (main.zig now keeps each import's AST alive instead of freeing it early). Deliberately scoped to `@callback` interfaces only (`resetNonCallbackInterfaces` undoes the fill for entity interfaces after each imported unit) — entity interfaces share the same flattening code (`collectInterfaceMembers`) but rely on it never having real cross-module content (native Zig vtable literals, C++'s `nativeHandleBase` single-candidate assumption); fixing that too is separate, unscoped future work. Also fixed a companion bug: `cApiTypeRef`'s sequence-typedef parameter rendering used the typedef's bare `.name` instead of its qualified name, breaking as soon as the flattened operation's type lived in a different module than the one being emitted. Also fixed: the Zig backend's `zidl_rt` import-need detection didn't account for a file whose *only* callback interface is a newly-added one with no prior typesupport/pl_cdr/c-api trigger. Note: `fillFromImportedAst` only fills each *directly* imported unit's own AST — a `@callback interface` base that itself inherits from a type in a second, transitively-imported file is not filled. This is not a new gap: `main.zig`'s import resolution (`processFile`) has only ever scanned the primary file's own top-level `import_dcl`s, so a file with its own imports already fails semantic analysis (`'X' is not declared`) the moment it's used as anyone's import — transitive imports are unsupported across the whole pipeline, confirmed by direct repro, not something this fix introduced or could locally fix. |

---

## C-ABI Interface / Callback Type Coverage

The C-ABI primary interface design commits to a hard constraint: **every type that appears
in a vtable slot or `@callback` listener callback parameter must be C-ABI representable.**
All DDS DCPS status types currently satisfy this constraint (flat structs of primitives,
enums, and fixed-size handles). This section tracks test coverage for that guarantee and
planned mitigation work for types that currently fail it.

### Positive test coverage

Each row is a test case that should exist in the backend unit test suite confirming that
the named type category works correctly as an interface or `@callback` callback parameter.

| Type category | IDL example | Status |
|---|---|---|
| All primitive types | `void f(in long x, in boolean b)` | ✓ covered by existing golden |
| Named struct parameter | `void f(in MyStatus s)` | ✓ covered by existing golden |
| Named sequence typedef parameter | `void f(in StringSeq s)` | ✓ covered by DDS listener golden |
| Named enum parameter | `void f(in MyEnum e)` | ✓ covered by existing golden |
| `string` parameter | `void f(in string s)` | ✓ covered by existing golden |
| Entity fat-pointer parameter | `void on_data(in DataReader r)` | ✓ covered by DDS listener golden |
| Fixed-size array typedef parameter | `void f(in MyByteArray a)` | missing — add to `types.idl` golden |
| Nested named struct parameter | `void f(in OuterStatus s)` | missing — add to `types.idl` golden |

### Negative test coverage

Each row is a case that **must** produce a named error from the generator rather than
silently emitting broken or type-unsafe C. A `// TODO` comment or a `void *` fallback
is not acceptable — it compiles but produces wrong behaviour at runtime.

| Type category | IDL example | Current behaviour | Target behaviour |
|---|---|---|---|
| `map<K,V>` parameter | `void f(in map<string,long> m)` | C backend errors on map in structs; interface/callback position not separately tested | Hard error: "map not C-ABI representable in interface parameter; use a named opaque typedef" |
| Anonymous/inline sequence parameter | `void f(in sequence<string> s)` | Untested; likely silent wrong emit | Hard error: "anonymous sequence not C-ABI representable; add a typedef" |
| Discriminated union parameter | `void f(in MyUnion u)` | C backend has no union-in-interface test; output untested | Hard error: "union not C-ABI representable in interface parameter (C union is untagged)" |
| `wstring` parameter | `void f(in wstring s)` | Emits `wchar_t *`; silently platform-width-dependent | Warning or hard error: "wstring ABI width is platform-dependent; use a fixed-width typedef" |
| `fixed<D,S>` parameter | `void f(in fixed<10,2> x)` | Emits `// TODO` comment | Hard error: "fixed_pt not C-ABI representable in interface parameter" |
| `valuetype` parameter | `void f(in MyValueType v)` | Untested | Hard error |
| Sequence-of-non-C-type typedef | `typedef sequence<MyUnion> UnionSeq; void f(in UnionSeq s)` | Untested; element type check missing | Hard error propagating from union element |

Each negative case should have a dedicated unit test in `src/backend/zig.zig` and
`src/backend/c.zig` asserting that the generator returns an appropriate error (not a
successful codegen that happens to be wrong).

### Mitigation work

The items below describe what it would take to move each negative case into the
positive column, ordered by impact (likelihood of appearing in real DDS-adjacent IDL)
and implementation complexity.

**1. Anonymous/inline sequences → synthesize a typedef**

When `sequence<T>` appears directly as an interface parameter type with no prior
typedef, automatically synthesize one:
`typedef sequence<T> _ZidlGen_<InterfaceName>_<OpName>_<ParamName>_Seq;`
and emit the corresponding extern struct before the callback struct or vtable
declaration. Purely mechanical; no semantic change. Covers the most common
case of a developer writing `sequence<string>` inline without thinking about it.

*Impact: medium. Risk: low.*

**2. Discriminated union → OMG C PSM companion struct**

IDL `union` has no direct C-ABI equivalent because C unions are untagged.
The OMG C PSM (formal/02-06-01) defines the canonical mapping:

```c
typedef struct MyUnion {
    long _d;        /* discriminant */
    union {
        MyStruct s; /* case 1 */
        long n;     /* case 2 */
        bool b;     /* default */
    } _u;
} MyUnion;
```

The Zig-side representation stays a tagged union. A generated conversion
function translates between them in the `@callback` comptime thunk. This
is well-specified by the OMG but non-trivial to wire into the thunk generator.

*Impact: medium. Risk: medium (conversion thunk in comptime wrapper).*

**3. `wstring` → fixed-width `uint16_t *`**

DDS RTPS encodes wstring as UTF-16LE (2-byte code units). The platform-dependent
`wchar_t` is the wrong type for cross-ABI use. Replace with `uint16_t *` (or
`typedef uint16_t DDS_WChar; DDS_WChar *`) to make ABI width deterministic.
Mechanical, but breaks existing C callers passing `wchar_t` literals.

*Impact: low (wstring is uncommon in modern DDS profiles). Risk: low once decided.*

**4. `fixed<D,S>` → runtime struct in `zidl_cdr.h`**

Define `typedef struct { uint8_t digits[16]; uint8_t scale; } zidl_fixed_t;` in the
runtime header and emit `zidl_fixed_t` for `fixed<D,S>` parameters. No precision
validation in the ABI; caller's responsibility. Straightforward.

*Impact: very low (fixed-point is almost never used in DDS). Risk: very low.*

**5. `map<K,V>` → opaque handle + accessor functions**

No C struct can represent an arbitrary hash map. The practical path is an opaque
handle (`typedef struct ZidlMap_s *ZidlMap;`) with generated free functions:
`ZidlMap_get`, `ZidlMap_set`, `ZidlMap_iter`. On the Zig side the map remains a
native hash map; the thunk wraps a pointer to it.

Maps rarely appear in DDS API surfaces (they mostly appear in user data types, which
bypass the vtable as opaque CDR bytes). Best deferred until a concrete use case in
DDS API IDL arises.

*Impact: low. Risk: high (non-trivial generated accessor surface).*

---

## Python backend (`-b python`)

Target: Python 3.10+. No OMG spec; pragmatic conventions. Inline CDR (no companion
runtime package), following Java's model.

**Type mapping**:
- `struct` → `@dataclass(slots=True)` with typed fields
- `enum` → `enum.IntEnum`
- `union` → class with `_d: DiscType` property + `T | None` case properties; `match` dispatch in deserialize
- `sequence<T>` / `T[N]` → `list[T]` (array length checked at serialize time)
- `map<K,V>` → `dict[K, V]`
- `string` / `wstring` → `str`
- `@optional` → `T | None` (default `None`)
- Module → Python module namespace (flat file; `--split-files` emits per-type `.py` files)
- `@key` → `serialize_key()`, `deserialize_key()`, and `compute_key_hash()` methods
- No TypeObject generation (deferred — TypeObject is Zig-specific for now)

**CDR**: inline `struct.pack`/`struct.unpack` with an alignment-tracking writer/reader
class generated at the top of each output file. XCDR2 LE baseline; `@appendable` emits
DHEADER; `@mutable` emits EMHEADER per member.

**Implementation steps**:
1. `src/backend/python.zig` — declarations: struct/enum/union/typedef/const; `--no-typesupport` path
2. Python CDR: `@final` struct + union serialize/deserialize; inline writer/reader helper
3. Python CDR: `@appendable` (DHEADER), `@mutable` (EMHEADER), sequences, arrays, maps
4. Python CDR: `@key`, `deserialize_key`, `compute_key_hash`, `@optional`, wstring, fixed-pt
5. Python: `--split-files`, `--python-package <pkg>` option, tests, golden snapshot
6. Python integration test (roundtrip via subprocess or embedded interpreter)

---

## C# / .NET backend (`-b csharp`)

Target: `netstandard2.1` (covers Unity/Mono, .NET Core 3+, .NET 5–10+). C# 10+ syntax
(file-scoped namespaces). Spec: [IDL4 to C# v1.0 Beta (ptc/20-03-02)](https://www.omg.org/spec/IDL4-CSHARP/1.0/). Inline CDR
using `System.Buffers.BinaryPrimitives` + `Span<byte>`. No companion runtime package.

**Type mapping** (per formal/ptc-20-03-02):
- `struct` → `public sealed partial class` with auto-properties and a default constructor
- `enum` → C# `enum : int` (or underlying type per `@bit_bound`)
- `union` → `public sealed partial class` with discriminant property + typed case accessors
- `sequence<T>` → `List<T>`
- `T[N]` / `T[N1][N2]` → `T[]` / `T[][]`
- `map<K,V>` → `Dictionary<TKey, TValue>`
- `string` / `wstring` → `string`
- `@optional` → nullable value (`T?`)
- Module → `namespace` (nested modules → nested namespaces)
- `@key` → `SerializeKey`, `DeserializeKey`, and `ComputeKeyHash` methods
- No TypeObject generation (deferred)

**CDR**: inline `BinaryPrimitives`-based `CdrWriter`/`CdrReader` helper struct generated
at the top of each output file. `Span<byte>` for zero-copy primitives. XCDR2 LE baseline;
`@appendable` / `@mutable` follow same DHEADER/EMHEADER rules as Java.

**Implementation steps**:
1. `src/backend/dotnet.zig` — declarations: struct/enum/union/typedef/const; `--no-typesupport` path
2. C# CDR: `@final` struct + union serialize/deserialize; inline CdrWriter/CdrReader helpers
3. C# CDR: `@appendable` (DHEADER), `@mutable` (EMHEADER), sequences, arrays, maps
4. C# CDR: `@key`, `DeserializeKey`, `ComputeKeyHash`, `@optional`, wstring, fixed-pt
5. C# CDR: `--split-files`, `--dotnet-namespace <ns>` option, tests, golden snapshot
6. C# integration test (compile + roundtrip via `dotnet run`)

---

## Rust backend (`-b rust`)

Two generation modes selected via `--rust-runtime`:

- **`pure` (default)**: idiomatic Rust; `Vec<T>`, `String`, `HashMap`; CDR via `zidl-rs`
  companion crate (`no_std + alloc`). Target audience: desktop/server Rust projects that want
  a pure-Rust dep graph with no Zig runtime dependency.
- **`zig-ffi`**: zero-copy FFI into the Zig DDS runtime; sequences/strings as `ZidlSlice<T>`/
  `ZidlString` (`#[repr(C)]`, `no_std + alloc`); lifetime-annotated borrows for zero-copy
  deserialization; `--rust-types-crate <crate>` redirects the import source (default:
  `zidl_types`). A DDS implementation that wants to bundle the types re-exports from
  `zidl-types-rs` rather than reimplementing, preserving Rust type identity across the dep
  graph. Target audience: embedded and high-performance DDS consumers.

No OMG spec for Rust. No TypeObject generation (deferred — TypeObject is Zig-specific for now).

**Type mapping**:
- `struct` → Rust `struct` with named fields
- `enum` → Rust `enum` with unit variants; discriminant value via `#[repr(i32)]` etc.
- `union` → Rust `enum` with associated data (exhaustiveness checking); discriminant serialized separately
- `sequence<T>` → `Vec<T>` (pure) / `ZidlSlice<T>` (zig-ffi)
- `T[N]` → `[T; N]` — native fixed-size arrays, stack-allocated, no package needed
- `map<K,V>` → `HashMap<K, V>`
- `string` / `wstring` → `String` (pure) / `ZidlString` (zig-ffi)
- `@optional` → `Option<T>`
- `typedef` → `type` alias or newtype `struct Foo(Inner)`
- Module → `mod`
- `@key` → `serialize_key()`, `deserialize_key()`, and `compute_key_hash()` methods
- Structs annotated `#[repr(C)]` in zig-ffi mode where layout permits

**Implementation steps**:
1. `packages/zidl-types-rs/` — `ZidlSlice<T>`, `ZidlString` as `#[repr(C)]`; `no_std + alloc`
2. `src/backend/rust.zig` — declarations: struct/enum/union/typedef/const; `--no-typesupport` path; both runtime modes; `--rust-types-crate` flag wiring
3. `packages/zidl-rs/` — pure Rust CDR runtime: `CdrWriter`/`CdrReader`, XCDR1/XCDR2, alignment tracking, DHEADER/EMHEADER patching, `no_std + alloc`
4. Rust CDR (pure): `@final` struct + union serialize/deserialize
5. Rust CDR (pure): `@appendable` (DHEADER), `@mutable` (EMHEADER), sequences, arrays, maps
6. Rust CDR (pure): `@key`, `deserialize_key`, `compute_key_hash`, `@optional`, wstring, fixed-pt
7. Rust CDR (zig-ffi): zero-copy path — `ZidlSlice<T>`/`ZidlString` types, FFI serialization bindings, lifetime-annotated borrows for deserialized data
8. Rust: `--split-files`, `--rust-types-crate` wiring, tests, golden snapshot
9. Rust integration test (compile + roundtrip via `cargo test`)

---

## Haskell backend (`-b haskell`) — future consideration, not scheduled

Haskell ADTs are arguably the best semantic fit for IDL types of any language. Captured here
for future reference; no steps assigned.

**Type mapping** (strong fit):
- `struct` → record syntax `data MyStruct = MyStruct { field :: Int32, ... }`
- `union` → sum type with associated data; exhaustiveness checking at compile time
- `enum` → nullary constructors (labels converted `ALL_CAPS` → `UpperCamelCase`)
- `@optional` → `Maybe T` — perfect semantic fit
- `sequence<T>` → `[T]` or `Data.Vector.Vector T`
- `map<K,V>` → `Data.Map.Map K V`
- `string` / `wstring` → `Data.Text.Text` (Unicode-native)
- `typedef` → `type` alias (transparent) or `newtype` (type-safe)
- Module → Haskell module system

**Pain points**:
- CDR alignment tracking requires a custom writer monad (`newtype CdrPut a = CdrPut (StateT
  Int PutM a)`) — `binary`/`cereal` do not expose current byte position.
- DHEADER/EMHEADER size patching for `@appendable`/`@mutable` is awkward in pure functional
  style; requires two-pass, `MonadFix`, or a `ByteString` builder with known sizes.
- `T[N]` fixed-size arrays have no native representation; need `vector-sized`/DataKinds or
  runtime length checks with a plain list.
- `fixed<D,S>` has no standard Haskell type (`Data.Fixed` exists but uses type-level resolution).
- Two CDR strategy options: fully inline (large generated files, no external dep) vs. typeclass
  instances with a `zidl-hs` companion package on Hackage. The typeclass approach is more
  idiomatic but adds a distribution dependency.
