# Zero-copy bulk CDR: read views and write reservations

Status: accepted; phases 1 (read views, #98) and 2 (write reservations) built. Follows the bulk primitive array operations
(#92) and `zidl_cdr_read_sequence_count` (#96).

## Problem

The bulk operations replaced a function call per element with one `memcpy`,
or one byte-swapping loop, per array. For large primitive payloads, such as
images, point clouds and audio, the copy that remains dominates:

- **Decode:** the payload is copied out of a buffer that zzdds already holds
  on the application's behalf. A typed take decodes from the reader's own
  loaned buffer since zzdds #204.
- **Encode:** the producer fills its own array and zidl copies it into the
  CDR buffer. With a zzdds write loan, that buffer is the transport buffer.

Each case wants direct access to the wire bytes: a read *view* that points
into the input, and a write *reservation* that the producer fills in place.

## Constraints

- **Byte order.** Wire elements are in the stream's byte order. Only when it
  matches the host's can they be used, or filled, as host values in place.
- **Host alignment.** CDR aligns elements relative to the payload, which
  starts after the 4-byte encapsulation header, not relative to memory.
  - The C allocator returns 8-byte-aligned buffers, so an 8-byte element at
    payload offset 8k sits at an address congruent to 4 mod 8. In XCDR1 its
    8-byte alignment is therefore never met in memory.
  - XCDR2 aligns 8-byte elements only to 4 in the first place.
  - A reader's buffer can start anywhere, for example inside a datagram.

  A view or reservation can promise nothing about host alignment. It reports
  the alignment, and every typed use needs a fallback. Octets always qualify,
  and 2- and 4-byte elements usually do.
- **Buffer lifetime.** It differs by writer mode:
  - A dynamic writer reallocates as it grows, so a pointer into it is stale
    after its next write.
  - A fixed writer never moves. Generated code serializes write loans into a
    fixed writer.
  - A counting writer has no buffer.
  - A reader's buffer is the caller's, as for `zidl_cdr_read_string_zerocopy`,
    whose results are "valid as long as the buffer passed to
    `zidl_cdr_reader_init` stays alive".
- **Uninitialized output.** Reserved bytes are counted and sent whether or not
  the producer filled them. Bytes a dynamic writer has not written are left
  over from the allocator, so unfilled ones would leak memory onto the wire.

## Read views

```c
typedef struct ZidlCdrPrimitivesView {
    const uint8_t *data;   /* first element's wire bytes; NULL iff count == 0 */
    size_t count;
    size_t elem_size;      /* 1, 2, 4 or 8 */
    bool   swapped;        /* wire byte order differs from the host's */
} ZidlCdrPrimitivesView;

/* Consumes `count` elements as zidl_cdr_read_primitives does (alignment,
 * bounds, errors; unchanged on failure), but points at them instead of
 * copying. The view is valid while the reader's buffer is. */
int zidl_cdr_read_primitives_view(ZidlCdrReader *r, size_t count,
                                  size_t elem_size, ZidlCdrPrimitivesView *out);

/* The elements as host values in place: `data` if they are `elem_size`
 * bytes, unswapped and aligned to `align` in memory; otherwise NULL, and the
 * caller copies. */
const void *zidl_cdr_view_native(const ZidlCdrPrimitivesView *v,
                                 size_t elem_size, size_t align);
#if defined(__cplusplus)
#define ZIDL_CDR_VIEW_AS(v, T) \
    (static_cast<const T *>(zidl_cdr_view_native((v), sizeof(T), alignof(T))))
#elif __STDC_VERSION__ >= 201112L
#define ZIDL_CDR_VIEW_AS(v, T) \
    ((const T *)zidl_cdr_view_native((v), sizeof(T), _Alignof(T)))
#else /* C99: a primitive's alignment never exceeds its size */
#define ZIDL_CDR_VIEW_AS(v, T) \
    ((const T *)zidl_cdr_view_native((v), sizeof(T), sizeof(T)))
#endif

/* The fallback: copies the elements into `dest` as host values, swapping
 * if needed. It does not touch the reader. INVALID for a view of another
 * width or NULL pointers, rather than a crash. */
int zidl_cdr_view_copy(const ZidlCdrPrimitivesView *v, void *dest);
```

A consumer reads the count, takes a view, and uses the elements in place when
it can:

```c
uint32_t n;
ZidlCdrPrimitivesView v;
if ((rc = zidl_cdr_read_sequence_count(r, 4, bound, &n)) ||
    (rc = zidl_cdr_read_primitives_view(r, n, 4, &v))) return rc;
const float *f = ZIDL_CDR_VIEW_AS(&v, float);
if (!f) { /* allocate n floats, then */ zidl_cdr_view_copy(&v, buf); }
```

Byte order and alignment are not the only condition for reading in place. C
and C++ also forbid reading an object through a pointer to another type:
storage declared as `uint8_t bytes[N]` cannot be read as `float`s, however
aligned. Typed access through `ZIDL_CDR_VIEW_AS` is therefore valid only when
the reader's buffer is allocated storage with no declared type: `malloc`,
`mmap`, shared memory, or a zzdds loaned sample. In C++ the elements must also
be implicit-lifetime types (C++20 `std::start_lifetime_as` makes this explicit).
For any other buffer, use `zidl_cdr_view_copy`, or `memcpy` elements out of
`data`. Octets are exempt: `uint8_t` may alias anything.

`swapped` and `data` are public, so a consumer that handles byte order itself,
such as one forwarding raw bytes, needs neither helper. `bool` is not viewable
in this phase: its bytes must be checked to be 0 or 1. A later
`zidl_cdr_read_bool_view` could check them in place, without a copy.

## Write reservations

A reservation records an **offset**, not a pointer, so it survives a dynamic
writer's growth. The pointer is fetched when it is needed and is not kept
across writes.

```c
typedef struct ZidlCdrReservation {
    size_t offset;     /* of the first element, in the writer's buffer */
    size_t count;
    size_t elem_size;  /* 1, 2, 4 or 8 */
    bool   swap;       /* the writer's byte order differs from the host's */
    bool   committed;  /* set by zidl_cdr_commit_primitives */
} ZidlCdrReservation;

/* Pads and advances the writer as zidl_cdr_write_primitives does (padding
 * zeroed, all-or-nothing, same errors), leaving the elements for the caller.
 * A counting writer counts them. */
int zidl_cdr_reserve_primitives(ZidlCdrWriter *w, size_t count,
                                size_t elem_size, ZidlCdrReservation *out);

/* Where to fill the elements: NULL for a counting writer, a count of 0, or
 * a reservation not within what the writer has written. Valid until the
 * writer's next write, reserve or deinit, which may move a dynamic writer's
 * buffer; a fixed writer's never moves. Static inline. */
void *zidl_cdr_reservation_data(const ZidlCdrWriter *w,
                                const ZidlCdrReservation *res);

/* After the caller has filled the elements with host values: puts them in
 * the writer's byte order, in place, and marks the reservation committed.
 * Required before the buffer is used. A no-op without `swap`, for a
 * counting writer or a count of 0, and for a reservation already committed,
 * so a repeated call cannot swap the bytes back. INVALID for NULL
 * pointers, another width, or a reservation not within what the writer has
 * written. */
int zidl_cdr_commit_primitives(ZidlCdrWriter *w, ZidlCdrReservation *res);
```

The contract is to fill every element with host values, then commit once.
Commit is a no-op in the common case (a little-endian writer on a
little-endian host) and in a counting writer's sizing pass, but it is always
called. That keeps one contract for both byte orders and both writer passes,
and gives a place for future checks. A reservation remembers that it was
committed, so a second commit does nothing rather than swap the bytes back.

Host alignment again: `zidl_cdr_reservation_data` promises none, so a typed
fill writes through `memcpy` or unaligned stores. For 8-byte elements that is
the usual case (see Constraints).

**Write loans.** A producer sizes the sample with a counting writer, in which
the reservation just counts. It takes a loan of that size, serializes into a
fixed writer over the loaned buffer, and fills the reservation there. The
elements are then written once, straight into the transport buffer.

## Native Zig

The logic lives in the native codec, as for #92 and #96, and the C functions
adapt it:

- `CdrReader.viewPrimitives(width, count)` returns a view whose `bytes` is a
  slice into the input, and `.asNative(T)` returns `?[]align(1) const T`
  (null if swapped).
- `CdrWriter.reservePrimitives(width, count)` returns an offset-based
  reservation; `.slice(writer)` is invalidated by the next write, and
  `.commit(writer)` swaps in place.

Generated Zig code reads into its own containers and is unchanged.

## Phasing

1. **Read views:** `zidl_cdr_read_primitives_view`, `_view_native`,
   `ZIDL_CDR_VIEW_AS` and `_view_copy`, with the native view, for every
   width. Small, and its lifetime rule already exists.
2. **Write reservations:** `zidl_cdr_reserve_primitives`,
   `_reservation_data` and `_commit_primitives`, with the native
   reservation. The internal `zidl_cdr_shared_reserve_array` is most of it.
3. **Later, each its own design:** checked `bool` views, and generated-code
   integration, meaning sequence members that a loaned sample exposes as
   views. That second item is a binding-mapping change, not a CDR one.

## Decisions

1. **Unfilled reserved bytes are not zeroed.** Zeroing costs a memory pass
   over the payload, nearly what the copy did. Every element must be
   filled; a debug or test build may fill reservations with a pattern to
   catch gaps.
2. **A reservation records an offset**, and the pointer is fetched on
   demand: a pointer would be simpler for fixed writers but would dangle
   once a dynamic writer reallocates.
3. **Commit is always required**, even where it does nothing, rather than
   letting callers write wire order themselves and skip it.
4. **Phase 1 covers every width**, not octets alone: the alignment and swap
   reporting is what makes non-octet views safe, and it is the same code.
