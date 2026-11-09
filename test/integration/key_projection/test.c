#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef __cplusplus
#include "shapes.hpp"
#define TYPE(name) Projection::name
#define INIT {}
#define CLEAN(name, value) ((void)0)
#else
#include "shapes.h"
#define TYPE(name) Projection_##name
#define INIT {0}
#define CLEAN(name, value) Projection_##name##_free(&(value))
#endif
#define NONE(name, value) ((void)0)

typedef struct {
    char name[64]; int version, order;
    uint8_t full[1024], key[1024], hash[16]; size_t full_len, key_len;
} Vector;
static Vector vectors[32];
static size_t vector_count, checked;
static unsigned nibble(char c) { return c<='9' ? (unsigned)(c-'0') : (unsigned)(c-'a'+10); }
static size_t unhex(const char *s, uint8_t *out) {
    size_t n=strlen(s)/2;
    for (size_t i=0;i<n;i++) out[i]=(uint8_t)((nibble(s[2*i])<<4)|nibble(s[2*i+1]));
    return n;
}
static void load(const char *path) {
    FILE *f=fopen(path,"r"); assert(f);
    char name[64], full[2049], key[2049], hash[33]; int version, order;
    while (fscanf(f,"%63s %d %d %2048s %2048s %32s",name,&version,&order,full,key,hash)==6) {
        assert(vector_count<32); Vector *v=&vectors[vector_count++];
        strcpy(v->name,name); v->version=version; v->order=order;
        v->full_len=unhex(full,v->full); v->key_len=unhex(key,v->key); assert(unhex(hash,v->hash)==16);
    }
    fclose(f); assert(vector_count==24);
}

#ifndef __cplusplus
static struct { void *ptr; size_t size; } live[64];
static size_t live_count;
static int allocations_left=-1;
static void *allocate(void *ctx, size_t size, size_t alignment) {
    (void)ctx; (void)alignment;
    if (allocations_left==0) return NULL;
    if (allocations_left>0) allocations_left--;
    void *p=malloc(size); assert(p && live_count<64);
    live[live_count].ptr=p; live[live_count++].size=size;
    return p;
}
static bool resize_block(void *ctx, void *ptr, size_t old_size, size_t new_size, size_t alignment) {
    (void)ctx; (void)ptr; (void)old_size; (void)new_size; (void)alignment; return false;
}
static void release(void *ctx, void *ptr, size_t size, size_t alignment) {
    (void)ctx; (void)alignment;
    if (!ptr) return;
    for (size_t i=0;i<live_count;i++) if (live[i].ptr==ptr) {
        assert(live[i].size==size); live[i]=live[--live_count]; free(ptr); return;
    }
    abort();
}
#endif

static size_t frame_offsets(const char *name, const size_t **offsets) {
    static const size_t scalar[]={4}, mut[]={4,12,16,32,36}, array[]={4,8,16}, seq[]={4,12,32};
    if (!strcmp(name,"ADerived") || !strcmp(name,"MDerived")) { *offsets=scalar; return 1; }
    if (!strcmp(name,"RootMut")) { *offsets=mut; return 5; }
    if (!strcmp(name,"RootArray")) { *offsets=array; return 3; }
    if (!strcmp(name,"RootSeq")) { *offsets=seq; return 3; }
    *offsets=NULL; return 0;
}
static uint32_t word(const uint8_t *data, int order) {
    uint32_t n=0;
    for (unsigned i=0;i<4;i++) n|=(uint32_t)data[i]<<(8*(order ? 3-i : i));
    return n;
}
static void put_word(uint8_t *data, int order, uint32_t n) {
    for (unsigned i=0;i<4;i++) data[i]=(uint8_t)(n>>(8*(order ? 3-i : i)));
}

#define CHECK(NAME, VALUE, FREE_VALUE) do { \
    for (size_t _i=0;_i<vector_count;_i++) { \
        const Vector *_e=&vectors[_i]; if (strcmp(_e->name,#NAME)) continue; \
        uint8_t _hash[16], _buffer[1024]; \
        assert(Projection_##NAME##_compute_key_hash(&(VALUE),_hash)==0 && !memcmp(_hash,_e->hash,16)); \
        for (int _key=0;_key<2;_key++) { \
            const uint8_t *_bytes=_key ? _e->key : _e->full; \
            size_t _len=_key ? _e->key_len : _e->full_len; \
            for (int _mode=0;_mode<3;_mode++) { \
                ZidlCdrWriter _w; \
                if (!_mode) assert(zidl_cdr_writer_init(&_w,_e->version)==0); \
                else if (_mode==1) zidl_cdr_writer_init_fixed(&_w,_buffer,sizeof _buffer,_e->version); \
                else zidl_cdr_writer_init_counting(&_w,_e->version); \
                zidl_cdr_writer_set_byte_order(&_w,_e->order); \
                assert(zidl_cdr_write_encap_kind(&_w,EXT_##NAME)==0); \
                assert((_key ? Projection_##NAME##_serialize_key(&_w,&(VALUE)) : Projection_##NAME##_serialize(&_w,&(VALUE)))==0); \
                assert(_w.len==_len); if (_mode!=2) assert(!memcmp(_w.buf,_bytes,_len)); \
                zidl_cdr_writer_deinit(&_w); \
            } \
            TYPE(NAME) _out=INIT; ZidlCdrReader _r; \
            assert(zidl_cdr_reader_init(&_r,_bytes,_len)==0); \
            assert((_key ? Projection_##NAME##_deserialize_key(&_r,&_out) : Projection_##NAME##_deserialize(&_r,&_out))==0); \
            assert(_r.pos==_len && _r.data_len==_len); \
            assert(Projection_##NAME##_compute_key_hash(&_out,_hash)==0 && !memcmp(_hash,_e->hash,16)); \
            FREE_VALUE(NAME,_out); \
            assert((_key ? Projection_##NAME##_compute_key_hash_from_cdr_key_only(_bytes,_len,_hash) : Projection_##NAME##_compute_key_hash_from_cdr(_bytes,_len,_hash))==0); \
            assert(!memcmp(_hash,_e->hash,16)); \
            for (size_t _n=4;_n<_len;_n++) { \
                TYPE(NAME) _partial=INIT; \
                assert(zidl_cdr_reader_init(&_r,_bytes,_n)==0); \
                assert((_key ? Projection_##NAME##_deserialize_key(&_r,&_partial) : Projection_##NAME##_deserialize(&_r,&_partial))!=0); \
                assert(_r.pos<=_n && _r.data_len==_n); FREE_VALUE(NAME,_partial); \
                memset(_hash,0xa5,16); \
                assert((_key ? Projection_##NAME##_compute_key_hash_from_cdr_key_only(_bytes,_n,_hash) : Projection_##NAME##_compute_key_hash_from_cdr(_bytes,_n,_hash))!=0); \
                for (size_t _j=0;_j<16;_j++) assert(_hash[_j]==0xa5); \
            } \
        } \
        const size_t *_offsets; size_t _count=(_e->version==2 ? frame_offsets(#NAME,&_offsets) : 0); \
        for (size_t _n=0;_n<_count;_n++) { \
            memcpy(_buffer,_e->key,_e->key_len); size_t _offset=_offsets[_n]; \
            put_word(_buffer+_offset,_e->order,word(_buffer+_offset,_e->order)-4); \
            TYPE(NAME) _partial=INIT; ZidlCdrReader _r; \
            assert(zidl_cdr_reader_init(&_r,_buffer,_e->key_len)==0); \
            assert(Projection_##NAME##_deserialize_key(&_r,&_partial)!=0); \
            assert(_r.data_len==_e->key_len && _r.pos<=_e->key_len); FREE_VALUE(NAME,_partial); \
            memset(_hash,0xa5,16); \
            assert(Projection_##NAME##_compute_key_hash_from_cdr_key_only(_buffer,_e->key_len,_hash)!=0); \
            for (size_t _j=0;_j<16;_j++) assert(_hash[_j]==0xa5); \
        } \
        checked++; \
    } \
} while(0)

#define EXT_FDerived ZIDL_EXT_FINAL
#define EXT_ADerived ZIDL_EXT_APPENDABLE
#define EXT_MDerived ZIDL_EXT_MUTABLE
#define EXT_RootBridge ZIDL_EXT_FINAL
#define EXT_RootInherited ZIDL_EXT_FINAL
#define EXT_RootMut ZIDL_EXT_MUTABLE
#define EXT_RootArray ZIDL_EXT_FINAL
#define EXT_RootSeq ZIDL_EXT_FINAL

static void set_final(TYPE(FDerived) *v) {
#ifdef __cplusplus
    v->ignored=99; v->id=42; v->middle=88;
#else
    v->_base._base.ignored=99; v->_base._base.id=42; v->_base.middle=88;
#endif
    v->tail=77;
}
static void set_mutable(TYPE(MDerived) *v, const char *key) {
#ifdef __cplusplus
    v->ignored=99; v->key=key;
#else
    v->_base._present=1; v->_base.ignored=99; v->_base.key=(char *)key;
#endif
    v->tail=77;
}
static void set_bridge(TYPE(MutBridge) *v, int before, const char *key, int after) {
    v->before=before; set_mutable(&v->inner,key); v->after=after;
}

#ifndef __cplusplus
#define FAILURES(NAME, FREE_VALUE) do { \
    for (size_t _i=0;_i<vector_count;_i++) if (!strcmp(vectors[_i].name,#NAME)) { \
        const Vector *_e=&vectors[_i]; \
        for (int _left=0;_left<8;_left++) { \
            uint8_t _hash[16]; memset(_hash,0xa5,16); allocations_left=_left; \
            int _rc=Projection_##NAME##_compute_key_hash_from_cdr_key_only(_e->key,_e->key_len,_hash); \
            allocations_left=-1; assert(live_count==0); \
            if (_rc) { for (size_t _j=0;_j<16;_j++) assert(_hash[_j]==0xa5); } \
            else assert(!memcmp(_hash,_e->hash,16)); \
        } \
    } \
} while(0)
#endif

int main(int argc, char **argv) {
    assert(argc==2); load(argv[1]);
#ifndef __cplusplus
    ZidlAllocator allocator={NULL,allocate,resize_block,release}; zidl_cdr_set_allocator(&allocator);
#endif
    TYPE(FDerived) final=INIT; set_final(&final); CHECK(FDerived,final,NONE);
    TYPE(ADerived) app=INIT;
#ifdef __cplusplus
    app.ignored=99; app.id=42;
#else
    app._base.ignored=99; app._base.id=42;
#endif
    app.tail=77; CHECK(ADerived,app,NONE);
    TYPE(MDerived) mut=INIT; set_mutable(&mut,"blue"); CHECK(MDerived,mut,CLEAN);
    TYPE(RootBridge) bridge=INIT; bridge.item.before=11; bridge.item.inner=final; bridge.item.after=22; bridge.ignored=66;
    CHECK(RootBridge,bridge,NONE);
    TYPE(RootInherited) inherited=INIT;
#ifdef __cplusplus
    inherited.item.before=11;
#else
    inherited.item._base.before=11;
#endif
    inherited.item.inner=final; inherited.item.after=22; inherited.ignored=66;
    CHECK(RootInherited,inherited,NONE);
    TYPE(RootMut) root_mut=INIT; set_bridge(&root_mut.item,11,"blue",22); root_mut.token=33; root_mut.ignored=66;
    CHECK(RootMut,root_mut,CLEAN);
    TYPE(RootArray) array=INIT; array.values[0].before=11; set_mutable(&array.values[0].inner,"blue");
    array.values[1].before=33; set_mutable(&array.values[1].inner,"orange"); array.ignored=66;
    CHECK(RootArray,array,CLEAN);
    TYPE(MutBridge) elements[2]={INIT,INIT};
    set_bridge(&elements[0],11,"blue",22); set_bridge(&elements[1],33,"orange",44);
    TYPE(RootSeq) seq=INIT; seq.ignored=66;
#ifdef __cplusplus
    seq.values={elements[0],elements[1]};
    seq.dynamic_values=seq.values;
#else
    seq.values._buffer=elements; seq.values._length=seq.values._maximum=2;
    seq.dynamic_values._buffer=elements; seq.dynamic_values._length=seq.dynamic_values._maximum=2;
#endif
    CHECK(RootSeq,seq,CLEAN);
#ifndef __cplusplus
    FAILURES(MDerived,CLEAN); FAILURES(RootMut,CLEAN); FAILURES(RootArray,CLEAN); FAILURES(RootSeq,CLEAN);
    assert(live_count==0); zidl_cdr_set_allocator(NULL);
#endif
    assert(checked==vector_count); puts("key projection: all vectors passed");
    return 0;
}
