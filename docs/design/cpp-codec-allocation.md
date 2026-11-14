# C++ codec allocation failures

Generated C++ codecs expose integer-returning C-linkage functions while values
use STL containers. Length validation rejects invalid sequences before their
containers allocate, but valid samples can still exhaust available storage.

## Implemented exception boundary

When C++ exceptions are enabled, generated public reader traversals translate
`std::bad_alloc` (including its subclasses) and `std::length_error` to the existing
`ZIDL_CDR_OVERFLOW` result. This matches the C codec's allocation/storage failure
status without changing the C ABI or the generated value representation.

The boundary covers ordinary, key-value and selected decoding of structs,
exceptions and unions. Nested readers use the same boundary. Key-hash callbacks
which decode a temporary propagate the failure and leave the caller's hash
unchanged when decoding fails. Skip traversal remains allocation-free.

The contract is a basic exception guarantee, not a transactional decode:

- Output must be a valid, constructed generated C++ value before the call.
- On failure, already decoded fields may have changed. Containers and active
  union state remain destructible; local temporaries unwind through RAII.
- Callers may destroy, reset or retry decoding into the output after failure.
- The reader retains its original input pointer and extent. Its cursor reports
  bounded progress; it is not rolled back to the starting position. Reinitialize
  or restore the reader before retrying the sample.
- Only storage-related exceptions are translated. Unexpected exceptions from a
  custom PMR resource are not silently converted to allocation errors.

Serializers report native writer allocation failures through the existing
integer status API. This change does not make generated C++ value copy/lifecycle
operations or DDS interface adapters non-throwing.

## Builds without exceptions

Generated codecs compile with exceptions and RTTI disabled: exception syntax is
selected using the compiler's exception feature macros. This compatibility does
not imply recoverable OOM. A conforming STL allocator signals failure by throwing;
returning null from `allocate` is not an alternative contract. PMR has the same
constraint. Exhaustion can terminate an exception-free build.

Recoverable failure without exceptions needs a separate, explicit storage mode.
The existing STL representation and allocation behavior are preserved until that
mode is designed and tested. The viable directions are:

1. **Preallocated STL decoding.** Decode only within storage supplied before the
   call; reject an operation before it could allocate. Capacity checks suffice
   for simple vectors and strings, but not for the complete generated mapping.
   Nested elements need their own prepared storage. Optional emplacement currently
   replaces values and loses prepared capacity. Union arms decode through local
   temporaries. Maps allocate individual nodes and have no `reserve` operation.
   A useful implementation must define support/rejection for each shape and
   validate admission before changing union or optional state.
2. **Fallible containers.** Add an explicit C++ mapping whose string, sequence and
   map operations return failure rather than throwing. This supports dynamic
   allocation through `ZidlAllocator`, but changes public value types and requires
   generated declarations, codec operations, cleanup and interface conversion
   support. Bounded inline storage and unbounded allocator-backed storage need
   separate rules.
3. **C storage and codecs.** Use the existing generated C representation and its
   fallible allocator interface in constrained C++ applications. This already
   provides checked allocation failure, but is a different application mapping
   from the STL C++ API.

A decoder memory budget is a complementary admission limit. It can reject a
valid sample that exceeds policy, but cannot guarantee that an allocation within
budget will succeed and therefore does not replace a fallible storage contract.

## Validation

`zig build test-cpp-codec-allocation` injects failure at every allocation of valid
samples, in both XCDR versions and byte orders, using ordinary STL and PMR values.
A test resource routes PMR through the same deterministic failpoint independently
of host library internals. Cases include sequences of owning strings, maps,
optional sequences, owning union arms, nested unions, IDL exceptions, key-value
decoding and key-hash callbacks. Tests check integer results, allocation cleanup,
reader bounds, untouched hash output on failed decode and retry after failure.
The length-error injection verifies the second translation path explicitly.

Both representations also compile and run a preallocated sample smoke test with
`-fno-exceptions -fno-rtti`. That test establishes build compatibility and normal
error reporting, not graceful handling of an attempted allocation's failure.
