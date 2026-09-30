// Known-answer checks for the C++ backend against reference encodings of
// ka.idl from an independent XTypes implementation (vectors.txt; its path is
// argv[1]).
//
// For each top-level type, in each reference encoding: zidl encodes the
// sample to exactly the reference bytes, including the representation id the
// type's extensibility selects (for Mut only the id: the reference uses
// EMHEADER length codes 5-7 and zidl writes 4); the reference bytes decode to
// a value that re-encodes to zidl's encoding of the same sample; and every
// truncated input fails.

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "ka.hpp"

#define CHECK(cond)                                                                   \
    do {                                                                              \
        if (!(cond)) {                                                                \
            std::fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #cond); \
            std::exit(1);                                                             \
        }                                                                             \
    } while (0)

namespace {

std::string vectors;

std::vector<uint8_t> vector_hex(const std::string &kind, const std::string &name, int xcdr) {
    const std::string key = kind + " " + name + " xcdr" + std::to_string(xcdr) + " ";
    const auto at = vectors.find(key);
    CHECK(at != std::string::npos);
    std::vector<uint8_t> out;
    for (size_t i = at + key.size(); i + 1 < vectors.size() && vectors[i] != '\n'; i += 2) {
        out.push_back(static_cast<uint8_t>(std::stoul(vectors.substr(i, 2), nullptr, 16)));
    }
    return out;
}

// The reference sample: the representation id the reference writes for this
// type and encoding, then the payload.
std::vector<uint8_t> vector(const std::string &name, int xcdr) {
    auto out = vector_hex("encap", name, xcdr);
    CHECK(out.size() == 2);
    out.push_back(0x00);
    out.push_back(0x00);
    const auto payload = vector_hex("data", name, xcdr);
    out.insert(out.end(), payload.begin(), payload.end());
    return out;
}

// `ext` is the type's ZIDL_EXT_* extensibility (as annotated in ka.idl): it
// selects the XCDR2 representation id.
template <typename T, typename Ser>
std::vector<uint8_t> encode(const T &value, int xcdr, int ext, Ser ser) {
    std::vector<uint8_t> buf(2048);
    ZidlCdrWriter w;
    zidl_cdr_writer_init_fixed(&w, buf.data(), buf.size(), xcdr == 1 ? ZIDL_XCDR1 : ZIDL_XCDR2);
    CHECK(zidl_cdr_write_encap_kind(&w, ext) == 0);
    CHECK(ser(&w, &value) == 0);
    buf.resize(w.pos + 4);
    return buf;
}

template <typename T, typename De>
int decode(const uint8_t *bytes, size_t len, T &out, De de) {
    ZidlCdrReader r;
    if (zidl_cdr_reader_init(&r, bytes, len) != 0) return -1;
    const int rc = de(&r, &out);
    if (rc == 0 && r.pos != len) return -2; // trailing bytes
    return rc;
}

template <typename T, typename Ser, typename De>
void check(const char *name, int ext, const T &sample, int xcdr, bool compare_bytes, Ser ser, De de) {
    const auto reference = vector(name, xcdr);
    const auto ours = encode(sample, xcdr, ext, ser);
    // Representation id always; the payload too, except for Mut.
    CHECK(std::equal(ours.begin(), ours.begin() + 4, reference.begin()));
    if (compare_bytes) CHECK(ours == reference);
    {
        T got;
        CHECK(decode(reference.data(), reference.size(), got, de) == 0);
        CHECK(encode(got, xcdr, ext, ser) == ours);
        T copy = got;
        CHECK(encode(copy, xcdr, ext, ser) == ours);
    }
    for (size_t cut = 0; cut < reference.size(); cut++) {
        T got;
        CHECK(decode(reference.data(), cut, got, de) != 0);
    }
    std::printf("  %-9s xcdr%d ok\n", name, xcdr);
}

KA::U make_u(int32_t d) {
    KA::U u;
    u._d(d);
    if (d == 1) u.i(7);
    else u.s("u");
    return u;
}

KA::Prims prims() {
    KA::Prims v;
    v.s_long = {1, -2, 3};
    v.s_octet = {1, 2, 3};
    v.s_bool = {true, false};
    v.s_ll = {1, -1};
    v.s_dbl = {1.5};
    v.s_short = {7, -8, 9};
    v.a_long[0][0] = 1;
    v.a_long[0][1] = 2;
    v.a_long[1][0] = 3;
    v.a_long[1][1] = 4;
    return v;
}

KA::NonPrims non_prims() {
    KA::NonPrims v;
    v.s_str = {"a", "bc"};
    v.s_bstr = {"xy", "z"};
    v.s_ubstr = {"uv", "", "w"};
    v.s_enum = {KA::Color::GREEN, KA::Color::BLUE};
    v.s_bm = {static_cast<KA::Flags>(KA::Flags_F0 | KA::Flags_F2), KA::Flags_F1};
    v.s_struct = {{"n1", 1}, {"n2", 2}};
    v.s_astruct = {{"x"}};
    v.s_union = {make_u(1), make_u(2)};
    v.t_seq = {"t"};
    return v;
}

KA::Nested nested() {
    KA::Nested v;
    v.s_seq = {{1, 2}, {3}};
    v.s_tseq = {{4}, {}};
    v.s_seq_str = {{"a"}, {"b", "c"}};
    v.s_seq_struct = {{{"q", 1}}};
    v.s_arr = {KA::Triple{1, 2, 3}, KA::Triple{4, 5, 6}};
    v.s_barr = {KA::Triple{7, 8, 9}};
    return v;
}

KA::Arrays arrays() {
    KA::Arrays v;
    v.a_str[0] = "p";
    v.a_str[1] = "q";
    v.a_enum[0] = KA::Color::BLUE;
    v.a_enum[1] = KA::Color::RED;
    v.a_struct[0] = {"s1", 1};
    v.a_struct[1] = {"s2", 2};
    v.a_str2[0][0] = "w";
    v.a_str2[0][1] = "x";
    v.a_str2[1][0] = "y";
    v.a_str2[1][1] = "z";
    v.a_tarr[0] = {1, 2, 3};
    v.a_tarr[1] = {4, 5, 6};
    v.a_seq[0] = {1};
    v.a_seq[1] = {2, 3};
    return v;
}

KA::App app() {
    KA::App v;
    v.np = non_prims();
    v.extra = {{"e", 5}};
    return v;
}

KA::Mut mut() {
    KA::Mut v;
    v.s_str = {"m"};
    v.s_long = {1, 2};
    v.s_octet = {9};
    v.s_ll = {5};
    v.s_short = {3};
    v.s_struct = {{"k", 4}};
    v.name = "nm";
    v.a_long[0] = 6;
    v.a_long[1] = 7;
    v.a_struct[0] = {"a", 1};
    v.a_struct[1] = {"b", 2};
    v.nest = nested();
    return v;
}

} // namespace

int main(int argc, char **argv) {
    CHECK(argc == 2);
    std::ifstream in(argv[1]);
    CHECK(in.good());
    std::stringstream ss;
    ss << in.rdbuf();
    vectors = ss.str();
    for (int xcdr = 1; xcdr <= 2; xcdr++) {
        check("Prims", ZIDL_EXT_FINAL, prims(), xcdr, true, KA_Prims_serialize, KA_Prims_deserialize);
        check("NonPrims", ZIDL_EXT_FINAL, non_prims(), xcdr, true, KA_NonPrims_serialize, KA_NonPrims_deserialize);
        check("Nested", ZIDL_EXT_FINAL, nested(), xcdr, true, KA_Nested_serialize, KA_Nested_deserialize);
        check("Arrays", ZIDL_EXT_FINAL, arrays(), xcdr, true, KA_Arrays_serialize, KA_Arrays_deserialize);
        check("App", ZIDL_EXT_APPENDABLE, app(), xcdr, true, KA_App_serialize, KA_App_deserialize);
    }
    check("Mut", ZIDL_EXT_MUTABLE, mut(), 2, false, KA_Mut_serialize, KA_Mut_deserialize);
    std::printf("xcdr_known_answer C++: all checks passed\n");
    return 0;
}
