/* zidl_cdr_view.hpp: the C++ face of zidl_cdr.h's zero-copy primitive views
 * (docs/design/bulk-cdr-zero-copy.md), used by generated C++ view types
 * (--generate-views). Header-only; needs C++11. */
#ifndef ZIDL_CDR_VIEW_HPP
#define ZIDL_CDR_VIEW_HPP

#include <cstddef>
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

} // namespace zidl

#endif /* ZIDL_CDR_VIEW_HPP */
