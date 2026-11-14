# Existing map codec hardening

C++, Java and Zig maps retain the entry count in both XCDR representations.
XCDR2 additionally delimits maps unless both key and value types are primitive.
This follows the rule-15 correction in OMG issue DDSXTY14-72, also used by the
C map codecs. Old C++ nonprimitive map bytes omitted that delimiter; corrected
readers intentionally require the specified framing.

All three backends reject duplicate keys rather than silently overwriting,
ignoring them or reaching a container assertion. Writers check declared map
bounds. C++ and Zig check entry extents before allocating native containers;
Zig also checks the declared bound before reserving capacity. C++ ordinary
struct decoding retains its existing partial-output guarantee, with RAII
releasing temporary entries. It clears the destination map before inserting
valid entries, so reused output does not retain stale keys.

Zig generates ownership methods for maps, resolves unbounded string-key aliases
for content hashing, and frees both keys and values recursively. Per-entry
cleanup covers failures before insertion. Nested maps also support deep cloning
without sharing owned slices. Unsupported Zig key families require a separate
mapping implementation or an explicit diagnostic.

`test-map-admission` uses hand-constructed bytes independent of generated
serializers. Its primitive and nested owning examples check delimiter/count
framing; duplicate, truncated and allocation-failed reads exercise cleanup.
C++ runs in STL and PMR modes. C++ and Zig also decode a big-endian example;
Java retains its existing little-endian API. Zig exhausts nested decode/clone
allocations. The existing C++ allocation fixture covers both representations
and byte orders, now with the corrected nonprimitive map delimiter.

These tests establish the specified wire layout and failure behavior for the
covered shapes; they are not a claim of exhaustive vendor interoperability.
