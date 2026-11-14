#include "shapes.hpp"
#include <cassert>
#include <type_traits>
#include <cstring>

static_assert(std::is_same_v<decltype(Arrays::Values::direct), std::optional<std::array<int32_t, 2>>>);
static_assert(std::is_same_v<decltype(Arrays::Values::grid), std::optional<std::array<std::array<int32_t, 3>, 2>>>);
static_assert(std::is_same_v<decltype(Arrays::Values::aliased), std::optional<Arrays::Alias>>);
static_assert(std::is_same_v<decltype(Arrays::Values::rows), std::optional<std::array<Arrays::Row, 2>>>);

template<class T> static T sample(bool present) {
    T value{};
    value.tail = 0x12345678;
    if (present) {
        value.direct.emplace(); (*value.direct)[0]=11; (*value.direct)[1]=22;
        value.grid.emplace(); (*value.grid)[1][2]=33;
        value.aliased.emplace(); (*value.aliased)[1]=44;
        value.rows.emplace(); (*value.rows)[1][1]=55;
        value.words.emplace(); (*value.words)[0]="hello"; (*value.words)[1]="world";
    }
    return value;
}

template<class T> static void same(const T &a, const T &b) {
    assert(a.tail==b.tail && a.direct==b.direct && a.grid==b.grid);
    assert(a.aliased==b.aliased && a.rows==b.rows && a.words==b.words);
}

template<class T, auto Serialize, auto Deserialize> static void check(int version) {
    for (int order=ZIDL_CDR_LE; order<=ZIDL_CDR_BE; order++) {
        T decoded=sample<T>(true);
        for (bool present : {true, false, true}) {
            // Mutable reuse/reset semantics are covered by a separate follow-up.
            if constexpr (std::is_same_v<T,Arrays::Mut>) decoded={};
            const T value=sample<T>(present);
            uint8_t bytes[2048];
            ZidlCdrWriter w;
            zidl_cdr_writer_init_fixed(&w,bytes,sizeof bytes,version);
            zidl_cdr_writer_set_byte_order(&w,order);
            assert(zidl_cdr_write_encap_kind(&w, std::is_same_v<T,Arrays::Mut> ? ZIDL_EXT_MUTABLE : ZIDL_EXT_FINAL)==0);
            assert(Serialize(&w,&value)==0);
            ZidlCdrWriter count;
            zidl_cdr_writer_init_counting(&count,version);
            zidl_cdr_writer_set_byte_order(&count,order);
            assert(zidl_cdr_write_encap_kind(&count,std::is_same_v<T,Arrays::Mut> ? ZIDL_EXT_MUTABLE : ZIDL_EXT_FINAL)==0);
            assert(Serialize(&count,&value)==0 && count.len==w.len);
            ZidlCdrReader r;
            assert(zidl_cdr_reader_init(&r,bytes,w.len)==0);
            assert(Deserialize(&r,&decoded)==0 && r.pos==w.len);
            same(value,decoded);
            for (size_t cut=4; cut<w.len; cut++) {
                T partial{};
                assert(zidl_cdr_reader_init(&r,bytes,cut)==0);
                assert(Deserialize(&r,&partial)!=0);
                assert(r.pos<=cut);
            }
        }
    }
}

static void appendable() {
    for (int version=ZIDL_XCDR1; version<=ZIDL_XCDR2; version++) {
        for (int order=ZIDL_CDR_LE; order<=ZIDL_CDR_BE; order++) {
            for (bool present : {false, true}) {
                Arrays::App value{};
                value.tail=77;
                if (present) value.value=sample<Arrays::Values>(true);
                uint8_t bytes[2048]; ZidlCdrWriter w;
                zidl_cdr_writer_init_fixed(&w,bytes,sizeof bytes,version);
                zidl_cdr_writer_set_byte_order(&w,order);
                assert(zidl_cdr_write_encap_kind(&w,ZIDL_EXT_APPENDABLE)==0);
                assert(Arrays_App_serialize(&w,&value)==0);
                Arrays::App decoded{}; ZidlCdrReader r;
                assert(zidl_cdr_reader_init(&r,bytes,w.len)==0);
                assert(Arrays_App_deserialize(&r,&decoded)==0 && r.pos==w.len);
                assert(decoded.tail==77 && decoded.value.has_value()==present);
                if (present) same(*value.value,*decoded.value);
            }
        }
    }
}

int main() {
    appendable();
    check<Arrays::Values,Arrays_Values_serialize,Arrays_Values_deserialize>(ZIDL_XCDR1);
    check<Arrays::Values,Arrays_Values_serialize,Arrays_Values_deserialize>(ZIDL_XCDR2);
    check<Arrays::Mut,Arrays_Mut_serialize,Arrays_Mut_deserialize>(ZIDL_XCDR2);
}
