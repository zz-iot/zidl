/* Hand-written design fixture, not a generated or production ABI. */
#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

typedef struct View View;
typedef struct { uint64_t hi, lo; } InterfaceId;
enum { OK, CAPACITY, UNSUPPORTED };
typedef struct {
    uint32_t version, size;
    int (*retain)(const View *);
    void (*release)(const View *);
    const void *(*identity)(const View *);
    int (*query)(const View *, InterfaceId, const View **);
} Provider;
struct View { const Provider *provider; void *owner; void *target; };
typedef struct { int value; } Target;
typedef struct {
    unsigned refs, limit, finalizations;
    Target left, right;
    View a, b;
} Object;
static int retain(const View *v) {
    Object *o = v->owner;
    assert(o->refs);
    if (o->refs == o->limit) return CAPACITY;
    ++o->refs;
    return OK;
}
static void release(const View *v) {
    Object *o = v->owner;
    assert(o->refs);
    if (!--o->refs) ++o->finalizations;
}
static const void *identity(const View *v) { return v->owner; }
static int query(const View *v, InterfaceId id, const View **out) {
    Object *o = v->owner;
    *out = NULL;
    if (id.hi || (id.lo != 1 && id.lo != 2)) return UNSUPPORTED;
    const View *r = id.lo == 1 ? &o->a : &o->b;
    int rc = retain(r);
    if (!rc) *out = r;
    return rc;
}
static const Provider provider = {1, sizeof(Provider), retain, release, identity, query};
static void clear(const View **slot) {
    const View *old = *slot;
    *slot = NULL;
    if (old) old->provider->release(old);
}
static int assign(const View **slot, const View *input) {
    if (*slot == input) return OK;
    int rc = input ? input->provider->retain(input) : OK;
    if (rc) return rc;
    const View *old = *slot;
    *slot = input;
    if (old) old->provider->release(old);
    return OK;
}
typedef struct { const View *first, *second; } Config;
static void fini(Config *c) { clear(&c->first); clear(&c->second); }
static int clone(Config *dst, const Config *src) {
    assert(!dst->first && !dst->second);
    Config tmp = {0};
    int rc = assign(&tmp.first, src->first);
    if (!rc) rc = assign(&tmp.second, src->second);
    if (rc) { fini(&tmp); return rc; }
    *dst = tmp; /* explicit transfer of tmp's two obligations */
    return OK;
}
int main(void) {
    Object o = {.refs=1, .limit=16, .left={11}, .right={22}};
    o.a = (View){&provider, &o, &o.left};
    o.b = (View){&provider, &o, &o.right};
    const View *app = &o.a, *other = NULL;
    assert(!query(app, (InterfaceId){0,2}, &other));
    assert(identity(app) == identity(other) && app->target != other->target);
    assert(((Target *)other->target)->value == 22);
    Config c = {0}, copy = {0};
    assert(!assign(&c.first, app) && !assign(&c.second, other));
    unsigned before = o.refs;
    assert(!assign(&c.first, c.first) && o.refs == before);
    o.limit = o.refs + 1; /* fail second retain after first succeeded */
    assert(clone(&copy, &c) == CAPACITY);
    assert(!copy.first && !copy.second && o.refs == before);
    const View *bad = NULL;
    assert(query(app, (InterfaceId){0,99}, &bad) == UNSUPPORTED && !bad);
    o.limit = 16;
    assert(!clone(&copy, &c));
    fini(&c); clear(&app); clear(&other);
    assert(o.refs == 2 && !o.finalizations);
    fini(&copy); fini(&copy);
    assert(!o.refs && o.finalizations == 1);
    puts("PASS: view adjustment, identity, self-assignment, partial clone failure, final release");
}
