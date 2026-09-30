// Compile-and-run checks for the C++ backend's sequences of struct/union
// elements and aliases (see fixture.idl for the regressions covered).
//
// C++ sequences are std::vector and strings std::string, so ownership is
// automatic; the regressions here were compile errors (union CDR prototype
// linkage, @optional decode). These checks also round-trip every holder,
// decode every truncated prefix, and copy decoded values.

#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "fixture.hpp"

#define CHECK(cond)                                                              \
    do {                                                                         \
        if (!(cond)) {                                                           \
            std::fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #cond); \
            std::exit(1);                                                        \
        }                                                                        \
    } while (0)

namespace {

struct Wire {
    uint8_t buf[1024];
    size_t len = 0; // including the 4-byte encapsulation header
};

template <typename T, typename Ser>
Wire encode(const T &value, Ser ser) {
    Wire wire;
    ZidlCdrWriter w;
    zidl_cdr_writer_init_fixed(&w, wire.buf, sizeof wire.buf, ZIDL_XCDR2);
    CHECK(zidl_cdr_write_encap(&w) == 0);
    CHECK(ser(&w, &value) == 0);
    wire.len = w.pos + 4;
    return wire;
}

template <typename T, typename De>
int decode(const Wire &wire, size_t len, T &out, De de) {
    ZidlCdrReader r;
    if (zidl_cdr_reader_init(&r, wire.buf, len) != 0) return -1;
    return de(&r, &out);
}

// Full decode succeeds and matches; every strict prefix fails cleanly; a
// copy of the decoded value outlives the original.
template <typename T, typename Ser, typename De, typename Check>
void round_trip(const T &value, Ser ser, De de, Check check) {
    const Wire wire = encode(value, ser);
    T copy;
    {
        T out;
        CHECK(decode(wire, wire.len, out, de) == 0);
        check(out);
        copy = out;
    }
    check(copy);
    for (size_t cut = 0; cut < wire.len; cut++) {
        T out;
        CHECK(decode(wire, cut, out, de) != 0);
    }
}

const std::vector<Named> kNames{{"alpha", 1}, {"beta", 2}, {"gamma", 3}};

bool same_names(const std::vector<Named> &got, size_t n) {
    if (got.size() != n) return false;
    for (size_t i = 0; i < n; i++) {
        if (got[i].label != kNames[i].label || got[i].id != kNames[i].id) return false;
    }
    return true;
}

Choice make_choice_int(int32_t v) {
    Choice c;
    c._d(0);
    c.i(v);
    return c;
}

Choice make_choice_str(const std::string &v) {
    Choice c;
    c._d(1);
    c.s(v);
    return c;
}

} // namespace

int main() {
    {
        UnboundedHolder v;
        v.items = kNames;
        round_trip(v, UnboundedHolder_serialize, UnboundedHolder_deserialize,
                   [](const UnboundedHolder &o) { CHECK(same_names(o.items, 3)); });
    }
    {
        TypedefUnboundedHolder v;
        v.items = kNames;
        round_trip(v, TypedefUnboundedHolder_serialize, TypedefUnboundedHolder_deserialize,
                   [](const TypedefUnboundedHolder &o) { CHECK(same_names(o.items, 3)); });
    }
    {
        NamedHolder v;
        v.items = kNames;
        v.tail = 7;
        round_trip(v, NamedHolder_serialize, NamedHolder_deserialize, [](const NamedHolder &o) {
            CHECK(same_names(o.items, 3));
            CHECK(o.tail == 7);
        });
    }
    {
        Outer v;
        v.inner.items = {kNames[0], kNames[1]};
        v.inner.tail = 9;
        v.x = 11;
        round_trip(v, Outer_serialize, Outer_deserialize, [](const Outer &o) {
            CHECK(same_names(o.inner.items, 2));
            CHECK(o.inner.tail == 9 && o.x == 11);
        });
    }
    {
        ChoiceHolder v;
        v.choices = {make_choice_int(5), make_choice_str("text"), make_choice_str("more")};
        round_trip(v, ChoiceHolder_serialize, ChoiceHolder_deserialize, [](const ChoiceHolder &o) {
            CHECK(o.choices.size() == 3);
            CHECK(o.choices[0]._d() == 0 && o.choices[0].i() == 5);
            CHECK(o.choices[1]._d() == 1 && o.choices[1].s() == "text");
            CHECK(o.choices[2].s() == "more");
        });
    }
    {
        PeopleCase v;
        v._d(1);
        v.people({kNames[0], kNames[1]});
        round_trip(v, PeopleCase_serialize, PeopleCase_deserialize, [](const PeopleCase &o) {
            CHECK(o._d() == 1);
            CHECK(same_names(o.people(), 2));
        });
    }
    {
        OptionalHolder v;
        v.maybe = std::vector<Named>{kNames[0], kNames[1]};
        round_trip(v, OptionalHolder_serialize, OptionalHolder_deserialize, [](const OptionalHolder &o) {
            CHECK(o.maybe.has_value());
            CHECK(same_names(*o.maybe, 2));
        });

        OptionalHolder absent;
        round_trip(absent, OptionalHolder_serialize, OptionalHolder_deserialize,
                   [](const OptionalHolder &o) { CHECK(!o.maybe.has_value()); });
    }
    {
        AliasElementHolder v;
        v.labels = {"one", "two"};
        v.points = {{1, 2}, {3, 4}};
        v.choices = {make_choice_str("aliased")};
        v.colors = {Color::GREEN, Color::BLUE};
        v.more = {"extra"};
        round_trip(v, AliasElementHolder_serialize, AliasElementHolder_deserialize,
                   [](const AliasElementHolder &o) {
                       CHECK(o.labels.size() == 2 && o.labels[1] == "two");
                       CHECK(o.points.size() == 2 && o.points[1].y == 4);
                       CHECK(o.choices.size() == 1 && o.choices[0].s() == "aliased");
                       CHECK(o.colors.size() == 2 && o.colors[1] == Color::BLUE);
                       CHECK(o.more.size() == 1 && o.more[0] == "extra");
                   });
    }
    std::printf("sequence_elements C++: all checks passed\n");
    return 0;
}
