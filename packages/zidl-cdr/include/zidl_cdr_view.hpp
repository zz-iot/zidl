/* zidl_cdr_view.hpp: the C++ face of zidl_cdr.h's zero-copy primitive views
 * and reservations (docs/design/bulk-cdr-zero-copy.md), used by generated C++
 * view and builder types (--generate-views). Header-only; needs C++11. */
#ifndef ZIDL_CDR_VIEW_HPP
#define ZIDL_CDR_VIEW_HPP

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <type_traits>
#include <vector>

#include "zidl_cdr.h"

namespace zidl {

/** Primitives of type `T` in place in a CDR input, in the stream's byte
 * order, valid while that input is. CDR aligns them relative to the payload,
 * not to memory, so `as_native` hands them out in place only when they are
 * unswapped and aligned for `T`; otherwise copy them with `copy_to` or
 * `to_vector`. In place access also needs storage C++ lets you read as `T`:
 * allocated storage such as a loaned sample, not a declared byte array. */
template <typename T>
class PrimitivesView {
    static_assert(std::is_arithmetic<T>::value && !std::is_same<T, bool>::value,
                  "a primitives view holds non-bool arithmetic elements");
    static_assert(sizeof(T) == 1 || sizeof(T) == 2 || sizeof(T) == 4 || sizeof(T) == 8,
                  "CDR primitives are 1, 2, 4 or 8 bytes");

public:
    PrimitivesView() = default;

    std::size_t size() const noexcept { return view_.count; }
    bool empty() const noexcept { return view_.count == 0; }
    /** Whether the wire byte order differs from the host's. */
    bool swapped() const noexcept { return view_.swapped; }

    /** The elements in place, or nullptr when they must be copied: swapped,
     * not aligned for `T`, or empty. */
    const T *as_native() const noexcept { return ZIDL_CDR_VIEW_AS(&view_, T); }

    /** Copies the `size()` elements into `dest` as host values. */
    void copy_to(T *dest) const noexcept {
        if (view_.count != 0) (void)zidl_cdr_view_copy(&view_, dest);
    }

    std::vector<T> to_vector() const {
        std::vector<T> out(view_.count);
        copy_to(out.data());
        return out;
    }

    /** The underlying C view; generated decoders read into it. */
    const ZidlCdrPrimitivesView &c_view() const noexcept { return view_; }
    ZidlCdrPrimitivesView *c_view() noexcept { return &view_; }

private:
    ZidlCdrPrimitivesView view_{nullptr, 0, sizeof(T), false};
};

/** Primitives of type `T` reserved in a CDR output for the caller to fill in
 * place: the write twin of `PrimitivesView`, as a builder type holds it. Set a
 * sequence's count with `resize` before serializing (an array reserves its
 * declared length). Once serialized into a fixed writer, `data()` is where the
 * elements go, until that writer's buffer is released. They are not zeroed:
 * fill every one, in host byte order. Committing puts them in the writer's
 * byte order. Typed stores (`as_native`) need storage C++ lets you write as
 * `T`, such as a write loan, and an address aligned for `T`. */
template <typename T>
class PrimitivesReservation {
    static_assert(std::is_arithmetic<T>::value && !std::is_same<T, bool>::value,
                  "a primitives reservation holds non-bool arithmetic elements");
    static_assert(sizeof(T) == 1 || sizeof(T) == 2 || sizeof(T) == 4 || sizeof(T) == 8,
                  "CDR primitives are 1, 2, 4 or 8 bytes");

public:
    PrimitivesReservation() = default;
    explicit PrimitivesReservation(std::size_t count) noexcept { res_.count = count; }

    std::size_t size() const noexcept { return res_.count; }
    bool empty() const noexcept { return res_.count == 0; }
    /** Sets how many elements a sequence reserves. */
    void resize(std::size_t count) noexcept {
        res_.count = count;
        data_ = nullptr;
    }

    /** Where the elements go, or nullptr: not serialized into a buffer, or empty. */
    unsigned char *data() noexcept { return data_; }
    /** The elements in place for typed stores, or nullptr when there are none
     * or they are not aligned for `T` (then use `copy_from`). */
    T *as_native() noexcept {
        if (!data_ || reinterpret_cast<std::uintptr_t>(data_) % alignof(T) != 0) return nullptr;
        return reinterpret_cast<T *>(data_);
    }
    /** Copies `size()` host values from `src` into place. */
    void copy_from(const T *src) noexcept {
        if (data_ && res_.count != 0) std::memcpy(data_, src, res_.count * sizeof(T));
    }

    /** Reserves `count` elements in `w`, padded as written elements would be;
     * generated serializers call it. On failure nothing is reserved. */
    int reserve(ZidlCdrWriter *w, std::size_t count) noexcept {
        const int rc = zidl_cdr_reserve_primitives(w, count, sizeof(T), &res_);
        data_ = rc == 0 ? static_cast<unsigned char *>(zidl_cdr_reservation_data(w, &res_)) : nullptr;
        return rc;
    }
    /** Puts the filled elements in `w`'s byte order, once; generated
     * publishing calls it. */
    int commit(ZidlCdrWriter *w) noexcept { return zidl_cdr_commit_primitives(w, &res_); }

    /** The underlying C reservation. */
    const ZidlCdrReservation &c_reservation() const noexcept { return res_; }

private:
    ZidlCdrReservation res_{0, 0, sizeof(T), false, false};
    unsigned char *data_ = nullptr;
};

} // namespace zidl

#endif /* ZIDL_CDR_VIEW_HPP */
