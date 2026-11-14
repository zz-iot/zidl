#include <cassert>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory_resource>
#include <cstddef>
#include <new>
#include <stdexcept>
#include "fixture.hpp"

static size_t live_allocations, attempts;
static size_t fail_at = std::numeric_limits<size_t>::max();
static bool inject_length_error;

void *operator new(size_t n) {
    if (attempts++ == fail_at) {
        fail_at = std::numeric_limits<size_t>::max();
        if (inject_length_error) throw std::length_error("injected container length failure");
        throw std::bad_alloc();
    }
    void *p = std::malloc(n ? n : 1);
    if (!p) throw std::bad_alloc();
    ++live_allocations;
    return p;
}
void operator delete(void *p) noexcept {
    if (p) { --live_allocations; std::free(p); }
}
void operator delete(void *p, size_t) noexcept { ::operator delete(p); }

// Route PMR through the same failpoint independently of whether the host
// new_delete_resource uses ordinary or aligned operator new internally.
class TestResource final : public std::pmr::memory_resource {
    void *do_allocate(size_t n, size_t alignment) override {
        assert(alignment <= alignof(std::max_align_t));
        return ::operator new(n);
    }
    void do_deallocate(void *p, size_t, size_t) override { ::operator delete(p); }
    bool do_is_equal(const std::pmr::memory_resource &other) const noexcept override {
        return this == &other;
    }
};

static const char text[] =
    "A valid string long enough to require allocation in both libc++ and libstdc++.";

// Each failure point must return an error with a destructible partial output,
// preserve the caller's reader limits and hash bytes, and permit a later retry.
template<class T, class Decode>
static void failures(const uint8_t *bytes, size_t length, Decode decode) {
    const size_t live_before = live_allocations;
    size_t allocation_count;
    {
        T value{};
        ZidlCdrReader r;
        assert(zidl_cdr_reader_init(&r, bytes, length) == 0);
        const size_t start = attempts;
        assert(decode(&r, &value) == ZIDL_CDR_OK);
        allocation_count = attempts - start;
        assert(allocation_count > 0 && r.pos == length);
    }
    assert(live_allocations == live_before);
    for (bool length_error : {false, true}) {
        inject_length_error = length_error;
        for (size_t i = 0; i < allocation_count; ++i) {
            {
                T value{};
                ZidlCdrReader r;
                assert(zidl_cdr_reader_init(&r, bytes, length) == 0);
                fail_at = attempts + i;
                assert(decode(&r, &value) == ZIDL_CDR_OVERFLOW);
                fail_at = std::numeric_limits<size_t>::max();
                assert(r.data_len == length && r.pos >= 4 && r.pos <= length);
                // Reuse after failure is permitted; output is not transactional.
                assert(zidl_cdr_reader_init(&r, bytes, length) == 0);
                assert(decode(&r, &value) == ZIDL_CDR_OK);
            }
            assert(live_allocations == live_before);
        }
    }
    inject_length_error = false;
}

static void strings(ZidlCdrWriter *w) {
    size_t header;
    assert(zidl_cdr_reserve_dheader_maybe(w, &header) == 0);
    assert(zidl_cdr_write_u32(w, 2) == 0);
    assert(zidl_cdr_write_string(w, text, sizeof text - 1) == 0);
    assert(zidl_cdr_write_string(w, text, sizeof text - 1) == 0);
    if (header != (size_t)-1) assert(zidl_cdr_patch_dheader_checked(w, header) == 0);
}

int main() {
    TestResource resource;
    auto *previous_resource = std::pmr::set_default_resource(&resource);
    for (int version = ZIDL_XCDR1; version <= ZIDL_XCDR2; ++version) {
        for (int order = ZIDL_CDR_LE; order <= ZIDL_CDR_BE; ++order) {
            uint8_t bytes[512];
            ZidlCdrWriter w;
            auto begin = [&] {
                zidl_cdr_writer_init_fixed(&w, bytes, sizeof bytes, version);
                zidl_cdr_writer_set_byte_order(&w, order);
                assert(zidl_cdr_write_encap(&w) == 0);
            };
            begin();
            strings(&w);
            const size_t key_length = w.len;
            failures<Allocation::Sample>(bytes, key_length, Allocation_Sample_deserialize_key_value);
            failures<Allocation::Failure>(bytes, key_length, Allocation_Failure_deserialize);
            assert(zidl_cdr_write_i32(&w, 7) == 0);
            failures<Allocation::Sample>(bytes, w.len, Allocation_Sample_deserialize);
            const size_t sample_length = w.len;
            // Hash callbacks leave the caller's output untouched on decode OOM.
            for (int key_only = 0; key_only < 2; ++key_only) {
                uint8_t hash[16]; std::memset(hash, 0xa5, sizeof hash);
                fail_at = attempts;
                int rc = key_only
                    ? Allocation_Sample_compute_key_hash_from_cdr_key_only(bytes, key_length, hash)
                    : Allocation_Sample_compute_key_hash_from_cdr(bytes, sample_length, hash);
                fail_at = std::numeric_limits<size_t>::max();
                assert(rc == ZIDL_CDR_OVERFLOW);
                for (uint8_t b : hash) assert(b == 0xa5);
            }
            begin();
            assert(zidl_cdr_write_i32(&w, 0) == 0);
            assert(zidl_cdr_write_string(&w, text, sizeof text - 1) == 0);
            failures<Allocation::Choice>(bytes, w.len, Allocation_Choice_deserialize);
            failures<Allocation::Nested>(bytes, w.len, Allocation_Nested_deserialize);

            // Constructing a callback temporary can allocate before decoding.
            for (int key_only = 0; key_only < 2; ++key_only) {
                begin();
                assert(zidl_cdr_write_i32(&w, 3) == 0);
                if (!key_only) {
                    assert(zidl_cdr_write_string(&w, text, sizeof text - 1) == 0);
                    assert(zidl_cdr_write_string(&w, text, sizeof text - 1) == 0);
                }
                auto callback = key_only ? Allocation_DefaultValue_compute_key_hash_from_cdr_key_only
                                         : Allocation_DefaultValue_compute_key_hash_from_cdr;
                uint8_t hash[16];
                const size_t baseline = live_allocations, start = attempts;
                assert(callback(bytes, w.len, hash) == 0);
                const size_t count = attempts - start;
                assert(count > 0 && live_allocations == baseline);
                for (bool length_error : {false, true}) {
                    inject_length_error = length_error;
                    for (size_t i = 0; i < count; ++i) {
                        std::memset(hash, 0xa5, sizeof hash);
                        fail_at = attempts + i;
                        assert(callback(bytes, w.len, hash) == ZIDL_CDR_OVERFLOW);
                        fail_at = std::numeric_limits<size_t>::max();
                        assert(live_allocations == baseline);
                        for (uint8_t b : hash) assert(b == 0xa5);
                    }
                }
                inject_length_error = false;
            }
            // Arm construction (including partially constructed arrays) must
            // preserve the old arm when an allocating default throws.
            for (int arm : {1, 2}) {
                begin();
                assert(zidl_cdr_write_i32(&w, arm) == 0);
                size_t array_header = (size_t)-1;
                if (arm == 2) assert(zidl_cdr_reserve_dheader_maybe(&w, &array_header) == 0);
                for (int i = 0; i < arm; ++i) {
                    assert(zidl_cdr_write_i32(&w, i) == 0);
                    assert(zidl_cdr_write_string(&w, text, sizeof text - 1) == 0);
                    assert(zidl_cdr_write_string(&w, text, sizeof text - 1) == 0);
                }
                if (array_header != (size_t)-1) assert(zidl_cdr_patch_dheader_checked(&w, array_header) == 0);
                failures<Allocation::DefaultChoice>(bytes, w.len, Allocation_DefaultChoice_deserialize);
                for (bool length_error : {false, true}) {
                    inject_length_error = length_error;
                    for (int i = 0; i < arm * 2; ++i) {
                        const size_t baseline = live_allocations;
                        {
                            Allocation::DefaultChoice value{};
                            value.number(17);
                            fail_at = attempts + (size_t)i;
                            bool caught = false;
                            try { value._d(arm); } catch (const std::bad_alloc&) { caught = true; }
                            catch (const std::length_error&) { caught = true; }
                            fail_at = std::numeric_limits<size_t>::max();
                            assert(caught && value._d() == 0 && value.number() == 17);
                            value._d(arm);
                        }
                        assert(live_allocations == baseline);
                    }
                }
                inject_length_error = false;
            }

            // Map decodes allocate both value strings and tree nodes.
            begin();
            assert(zidl_cdr_write_u32(&w, 2) == 0);
            for (int i = 0; i < 2; ++i) {
                assert(zidl_cdr_write_i32(&w, i) == 0);
                assert(zidl_cdr_write_string(&w, text, sizeof text - 1) == 0);
            }
            failures<Allocation::MapValue>(bytes, w.len, Allocation_MapValue_deserialize);

            if (version == ZIDL_XCDR2) {
                {
                    Allocation::DefaultMutableChoice input{};
                    input._d(1);
                    zidl_cdr_writer_init_fixed(&w, bytes, sizeof bytes, version);
                    zidl_cdr_writer_set_byte_order(&w, order);
                    assert(zidl_cdr_write_encap_kind(&w, ZIDL_EXT_MUTABLE) == 0);
                    assert(Allocation_DefaultMutableChoice_serialize(&w, &input) == 0);
                    failures<Allocation::DefaultMutableChoice>(bytes, w.len, Allocation_DefaultMutableChoice_deserialize);
                }
                Allocation::Optional input{};
                input.values.emplace();
                input.values->push_back(text);
                input.values->push_back(text);
                zidl_cdr_writer_init_fixed(&w, bytes, sizeof bytes, version);
                zidl_cdr_writer_set_byte_order(&w, order);
                assert(zidl_cdr_write_encap_kind(&w, ZIDL_EXT_MUTABLE) == 0);
                assert(Allocation_Optional_serialize(&w, &input) == 0);
                failures<Allocation::Optional>(bytes, w.len, Allocation_Optional_deserialize);
            }
        }
    }
    std::pmr::set_default_resource(previous_resource);
    assert(live_allocations == 0);
}
