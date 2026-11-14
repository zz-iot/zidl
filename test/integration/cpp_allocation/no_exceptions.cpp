// Compatibility smoke test only: startup prepares all STL storage. This does
// not claim recovery from an allocation attempted with exceptions disabled.
#include <cassert>
#include <cstring>
#include "fixture.hpp"

int main() {
    Allocation::Sample input{}, output{};
    input.values.push_back("a string long enough to exceed the implementation's small string storage");
    input.tail = 42;
    output.values.resize(1);
    output.values[0].reserve(input.values[0].size());
    uint8_t bytes[256];
    ZidlCdrWriter w;
    zidl_cdr_writer_init_fixed(&w, bytes, sizeof bytes, ZIDL_XCDR2);
    assert(zidl_cdr_write_encap(&w) == 0);
    assert(Allocation_Sample_serialize(&w, &input) == 0);
    ZidlCdrReader r;
    assert(zidl_cdr_reader_init(&r, bytes, w.len) == 0);
    assert(Allocation_Sample_deserialize(&r, &output) == 0);
    assert(output.values == input.values && output.tail == input.tail && r.pos == w.len);
    assert(zidl_cdr_reader_init(&r, bytes, w.len - 1) == 0);
    assert(Allocation_Sample_deserialize(&r, &output) == ZIDL_CDR_TRUNCATED);
}
