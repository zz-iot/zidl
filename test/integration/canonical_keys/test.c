/* Independent RTPS key bytes and hashes; see README.md for provenance. */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef __cplusplus
#include "keys.hpp"
#define TYPE(name) Canonical::name
#define INIT {}
#else
#include "keys.h"
#define TYPE(name) Canonical_##name
#define INIT {0}
#endif

typedef struct { char name[64]; uint8_t bytes[512], hash[16]; size_t len; unsigned force; } Vector;
static Vector vectors[32];
static size_t vector_count;
static unsigned nibble(char c) { return c <= '9' ? (unsigned)(c-'0') : (unsigned)(c-'a'+10); }
static size_t hex_bytes(const char *hex, uint8_t *out) {
    size_t n = strlen(hex)/2;
    for (size_t i=0; i<n; i++) out[i]=(uint8_t)((nibble(hex[2*i])<<4)|nibble(hex[2*i+1]));
    return n;
}
static const Vector *lookup(const char *name) {
    for (size_t i=0; i<vector_count; i++) if (!strcmp(name,vectors[i].name)) return &vectors[i];
    abort();
}
static void load(const char *path) {
    FILE *file=fopen(path,"r"); assert(file);
    char name[64],bytes[1025],digest[33]; unsigned force;
    while (fscanf(file,"%63s %1024s %32s %u",name,bytes,digest,&force)==4) {
        assert(vector_count<32);
        Vector *v=&vectors[vector_count++];
        strcpy(v->name,name); v->len=hex_bytes(bytes,v->bytes);
        assert(hex_bytes(digest,v->hash)==16); v->force=force;
    }
    fclose(file);
}

#define CHECK(NAME, VALUE, CASE, EXT, XCDR1_OK) do { \
    const Vector *_expected=lookup(CASE); \
    uint8_t _hash[16], _fixed[512]; \
    assert((unsigned)Canonical_##NAME##_KEY_HASH_FORCE_MD5==_expected->force); \
    assert(Canonical_##NAME##_compute_key_hash(&(VALUE),_hash)==ZIDL_CDR_OK); \
    assert(!memcmp(_hash,_expected->hash,16)); \
    for (int _mode=0; _mode<3; _mode++) { \
        ZidlCdrWriter _w; \
        if (!_mode) assert(zidl_cdr_writer_init(&_w,ZIDL_XCDR2)==0); \
        else if (_mode==1) zidl_cdr_writer_init_fixed(&_w,_fixed,sizeof _fixed,ZIDL_XCDR2); \
        else zidl_cdr_writer_init_counting(&_w,ZIDL_XCDR2); \
        zidl_cdr_writer_set_byte_order(&_w,ZIDL_CDR_BE); \
        assert(Canonical_##NAME##_serialize_key_holder(&_w,&(VALUE))==0); \
        assert(_w.len==_expected->len); \
        if (_mode!=2) { \
            assert(!memcmp(_w.buf,_expected->bytes,_w.len)); \
            zidl_cdr_compute_key_hash_for_type(_w.buf,_w.len,Canonical_##NAME##_KEY_HASH_FORCE_MD5,_hash); \
            assert(!memcmp(_hash,_expected->hash,16)); \
        } \
        zidl_cdr_writer_deinit(&_w); \
    } \
    for (int _version=1; _version<=2; _version++) for (int _order=0; _order<=1; _order++) { \
        if (_version==1 && !(XCDR1_OK)) continue; \
        ZidlCdrWriter _w; \
        assert(zidl_cdr_writer_init(&_w,_version)==0); \
        zidl_cdr_writer_set_byte_order(&_w,_order); \
        assert(zidl_cdr_write_encap_kind(&_w,EXT)==0); \
        assert(Canonical_##NAME##_serialize(&_w,&(VALUE))==0); \
        assert(Canonical_##NAME##_compute_key_hash_from_cdr(_w.buf,_w.len,_hash)==0); \
        assert(!memcmp(_hash,_expected->hash,16)); \
        zidl_cdr_writer_deinit(&_w); \
    } \
} while (0)

static FILE *open_sibling(const char *path, const char *name) {
    char sibling[4096];
    const char *slash=strrchr(path,'/');
#ifdef _WIN32
    const char *backslash=strrchr(path,'\\');
    if (backslash && (!slash || backslash>slash)) slash=backslash;
#endif
    size_t prefix=slash ? (size_t)(slash-path+1) : 0;
    assert(prefix+strlen(name)+1 <= sizeof sibling);
    memcpy(sibling,path,prefix); strcpy(sibling+prefix,name);
    FILE *file=fopen(sibling,"r"); assert(file);
    return file;
}

static Vector wire_vectors[3];
static void load_wire(const char *path) {
    FILE *file=open_sibling(path,"wire_ids.txt");
    for (size_t i=0;i<3;i++) {
        char bytes[1025]; assert(fscanf(file,"%63s %1024s",wire_vectors[i].name,bytes)==2);
        wire_vectors[i].len=hex_bytes(bytes,wire_vectors[i].bytes);
    }
    fclose(file);
}
#define CHECK_WIRE(NAME, VALUE, INDEX, EXT) do { \
    ZidlCdrWriter _w; assert(zidl_cdr_writer_init(&_w,ZIDL_XCDR2)==0); \
    assert(zidl_cdr_write_encap_kind(&_w,EXT)==0); \
    assert(Canonical_##NAME##_serialize(&_w,&(VALUE))==0); \
    assert(_w.len==wire_vectors[INDEX].len && !memcmp(_w.buf,wire_vectors[INDEX].bytes,_w.len)); \
    zidl_cdr_writer_deinit(&_w); \
} while(0)

static void wide_wire(const char *path) {
    FILE *file=open_sibling(path,"wide_wire.txt");
    char name[16],hex[1025]; int version,order;
    while (fscanf(file,"%15s %d %d %1024s",name,&version,&order,hex)==4) {
        uint8_t expected[512],hash[16]; size_t len=hex_bytes(hex,expected);
        ZidlCdrWriter w; assert(zidl_cdr_writer_init(&w,version)==0);
        zidl_cdr_writer_set_byte_order(&w,order); assert(zidl_cdr_write_encap(&w)==0);
        if (!strcmp(name,"seq")) {
            TYPE(WideSeq) value=INIT;
#ifdef __cplusplus
            value.values={std::wstring{L'A',(wchar_t)0x1234},std::wstring{}};
#else
            uint16_t elements[2][9]={{'A',0x1234},{0}};
            value.values._buffer=elements; value.values._length=2; value.values._maximum=2;
#endif
            assert(Canonical_WideSeq_serialize(&w,&value)==0);
            assert(Canonical_WideSeq_compute_key_hash_from_cdr(expected,len,hash)==0);
            assert(!memcmp(hash,lookup("WideSeq")->hash,16));
        } else if (!strcmp(name,"empty")) {
            TYPE(Wide17) value=INIT;
            assert(Canonical_Wide17_serialize(&w,&value)==0);
            assert(Canonical_Wide17_compute_key_hash_from_cdr(expected,len,hash)==0);
            assert(!memcmp(hash,lookup("Wide17")->hash,16));
        } else {
            TYPE(Wide16) value=INIT;
            uint16_t a=!strcmp(name,"pair") ? 0xd83d : 'A';
            uint16_t b=!strcmp(name,"pair") ? 0xde00 : 0x1234;
#ifdef __cplusplus
            value.text=std::wstring{(wchar_t)a,(wchar_t)b};
#else
            value.text[0]=a; value.text[1]=b;
#endif
            assert(Canonical_Wide16_serialize(&w,&value)==0);
            assert(Canonical_Wide16_compute_key_hash_from_cdr(expected,len,hash)==0);
            uint8_t canonical[16]={0,0,0,4,(uint8_t)(a>>8),(uint8_t)a,(uint8_t)(b>>8),(uint8_t)b};
            assert(!memcmp(hash,canonical,16));
        }
        assert(w.len==len && !memcmp(w.buf,expected,len));
        zidl_cdr_writer_deinit(&w);
        for (size_t n=4;n<len;n++) {
            ZidlCdrReader r; assert(zidl_cdr_reader_init(&r,expected,n)==0);
            assert((!strcmp(name,"seq") ? Canonical_WideSeq_skip(&r) : Canonical_Wide16_skip(&r))==ZIDL_CDR_TRUNCATED);
        }
    }
    fclose(file);
}

typedef struct { char name[64]; unsigned order; uint8_t bytes[512],hash[16]; size_t len; } KeyVector;
static KeyVector key_vectors[16];
static size_t key_vector_count;
static void load_key(const char *path) {
    FILE *file=open_sibling(path,"key_wire.txt");
    char name[64],hex[1025],hash[33]; unsigned order;
    while(fscanf(file,"%63s %u %1024s %32s",name,&order,hex,hash)==4) {
        assert(key_vector_count<16); KeyVector *v=&key_vectors[key_vector_count++];
        strcpy(v->name,name); v->order=order; v->len=hex_bytes(hex,v->bytes); assert(hex_bytes(hash,v->hash)==16);
    }
    fclose(file);
}
static const KeyVector *key_lookup(const char *name,unsigned order) {
    for(size_t i=0;i<key_vector_count;i++) if(key_vectors[i].order==order && !strcmp(name,key_vectors[i].name)) return &key_vectors[i];
    abort();
}
#define CHECK_KEY(NAME, VALUE, EXT) do { \
    for(unsigned _order=0;_order<2;_order++) { \
        const KeyVector *_v=key_lookup(#NAME,_order); uint8_t _buffer[512],_hash[16]; \
        for(int _mode=0;_mode<3;_mode++) { \
            ZidlCdrWriter _w; \
            if(!_mode) assert(zidl_cdr_writer_init(&_w,ZIDL_XCDR2)==0); \
            else if(_mode==1) zidl_cdr_writer_init_fixed(&_w,_buffer,sizeof _buffer,ZIDL_XCDR2); \
            else zidl_cdr_writer_init_counting(&_w,ZIDL_XCDR2); \
            zidl_cdr_writer_set_byte_order(&_w,_order); assert(zidl_cdr_write_encap_kind(&_w,EXT)==0); \
            assert(Canonical_##NAME##_serialize_key(&_w,&(VALUE))==0); assert(_w.len==_v->len); \
            if(_mode!=2) assert(!memcmp(_w.buf,_v->bytes,_v->len)); \
            zidl_cdr_writer_deinit(&_w); \
        } \
        assert(Canonical_##NAME##_compute_key_hash_from_cdr_key_only(_v->bytes,_v->len,_hash)==0); \
        assert(!memcmp(_hash,_v->hash,16)); \
        for(size_t _n=4;_n<_v->len;_n++) { \
            memset(_hash,0xcc,16); \
            assert(Canonical_##NAME##_compute_key_hash_from_cdr_key_only(_v->bytes,_n,_hash)!=0); \
            for(size_t _j=0;_j<16;_j++) assert(_hash[_j]==0xcc); \
        } \
    } \
} while(0)

static void put32(uint8_t *p,uint32_t value,unsigned order) {
    for(unsigned i=0;i<4;i++) p[order ? 3-i : i]=(uint8_t)(value>>(8*i));
}
static void key_frame_errors(void) {
    for(unsigned order=0;order<2;order++) {
        const KeyVector *v=key_lookup("Example",order); uint8_t data[512],hash[16]; assert(v->len==48);
        for(unsigned mode=0;mode<3;mode++) {
            memcpy(data,v->bytes,v->len);
            put32(data+(mode==0 ? 4 : mode==1 ? 12 : 36),mode==0 ? 12 : 4,order);
            memset(hash,0xcc,16);
            assert(Canonical_Example_compute_key_hash_from_cdr_key_only(data,v->len,hash)!=0);
            for(size_t i=0;i<16;i++) assert(hash[i]==0xcc);
        }
        /* A future tail inside the string member is skipped before the next member. */
        memcpy(data,v->bytes,25); memcpy(data+25,"FUTR",4); memcpy(data+29,v->bytes+25,v->len-25);
        put32(data+4,44,order); put32(data+12,13,order);
        assert(Canonical_Example_compute_key_hash_from_cdr_key_only(data,v->len+4,hash)==0);
        assert(!memcmp(hash,v->hash,16));
        /* LC=5 borrows the string length prefix instead of carrying NEXTINT. */
        memcpy(data,v->bytes,12); memcpy(data+12,v->bytes+16,v->len-16);
        put32(data+4,36,order); put32(data+8,0x50000028u,order);
        assert(Canonical_Example_compute_key_hash_from_cdr_key_only(data,v->len-4,hash)==0);
        assert(!memcmp(hash,v->hash,16));
        for(unsigned mu=0;mu<2;mu++) {
            memcpy(data,v->bytes,v->len); put32(data+4,48,order);
            put32(data+v->len,0x20000063u|(mu ? 0x80000000u : 0),order); put32(data+v->len+4,42,order);
            int rc=Canonical_Example_compute_key_hash_from_cdr_key_only(data,v->len+8,hash);
            if(mu) assert(rc==ZIDL_CDR_INVALID); else { assert(!rc); assert(!memcmp(hash,v->hash,16)); }
        }
        for(unsigned lc=4;lc<=7;lc++) {
            memcpy(data,v->bytes,v->len); put32(data+4,48,order);
            put32(data+v->len,(lc<<28)|99,order); put32(data+v->len+4,0xffffffffu,order);
            assert(Canonical_Example_compute_key_hash_from_cdr_key_only(data,v->len+8,hash)!=0);
        }
    }
    TYPE(Nested) value=INIT; ZidlCdrWriter w;
    assert(zidl_cdr_writer_init(&w,ZIDL_XCDR1)==0);
    assert(Canonical_Nested_serialize_key(&w,&value)==ZIDL_CDR_INVALID && w.len==0);
    zidl_cdr_writer_deinit(&w);
}
#ifndef __cplusplus
typedef struct { size_t calls,frees,size; } KeyStats;
static void *key_alloc(void *ctx,size_t size,size_t alignment) {
    KeyStats *s=(KeyStats *)ctx; (void)alignment; s->calls++; s->size=size; return malloc(size);
}
static bool key_resize(void *ctx,void *ptr,size_t old_size,size_t new_size,size_t alignment) {
    (void)ctx;(void)ptr;(void)old_size;(void)new_size;(void)alignment;return false;
}
static void key_free(void *ctx,void *ptr,size_t size,size_t alignment) {
    KeyStats *s=(KeyStats *)ctx;(void)alignment;assert(size==s->size);s->frees++;free(ptr);
}
static void key_cleanup(void) {
    const KeyVector *v=key_lookup("SeqAgg",0); uint8_t bytes[512],hash[16];
    memcpy(bytes,v->bytes,v->len); put32(bytes+12,4,0);
    KeyStats stats={0}; ZidlAllocator a={&stats,key_alloc,key_resize,key_free};
    zidl_cdr_set_allocator(&a);
    assert(Canonical_SeqAgg_compute_key_hash_from_cdr_key_only(bytes,v->len,hash)!=0);
    /* The sequence probe now rejects this malformed aggregate before its
     * container allocates, rather than allocating and cleaning up afterwards. */
    assert(stats.calls==0 && stats.frees==0);
    zidl_cdr_set_allocator(NULL);
}
#endif

static unsigned denied_allocations;
static void *deny_alloc(void *ctx,size_t size,size_t alignment) {
    (void)ctx; (void)size; (void)alignment; denied_allocations++; return NULL;
}
static bool deny_resize(void *ctx,void *p,size_t old_n,size_t new_n,size_t alignment) {
    (void)ctx; (void)p; (void)old_n; (void)new_n; (void)alignment; return false;
}
static void unexpected_free(void *ctx,void *p,size_t n,size_t alignment) {
    (void)ctx; (void)p; (void)n; (void)alignment; abort();
}

int main(int argc,char **argv) {
    assert(argc==2); load(argv[1]); load_wire(argv[1]); load_key(argv[1]);
    TYPE(Sequential) sequential=INIT;
    sequential.a=0xaa; sequential.b=0x05060708; sequential.c=0xcc; sequential.d=0x01020304;
    CHECK(Sequential,sequential,"Sequential",2,0);
    TYPE(Hashed) hashed=INIT; hashed.color=0xaa; hashed.size=0x01020304;
    CHECK(Hashed,hashed,"Hashed",2,0);
    TYPE(AutoDerived) auto_derived=INIT;
#ifdef __cplusplus
    auto_derived.base_value=0x05060708; auto_derived.tail=0xaa;
#else
    auto_derived._base.base_value=0x05060708; auto_derived._base.tail=0xaa;
#endif
    auto_derived.value=0x01020304;
    CHECK(AutoDerived,auto_derived,"AutoDerived",0,1);
    TYPE(UnionDefault) union_default=INIT;
#ifdef __cplusplus
    union_default.selection._d(0); union_default.selection.other(0x01020304);
#else
    union_default.selection._d=0; union_default.selection._u.other=0x01020304;
#endif
    CHECK(UnionDefault,union_default,"UnionDefault",0,0);
    CHECK_KEY(Sequential,sequential,2);
    CHECK_KEY(Hashed,hashed,2);
    CHECK_WIRE(Sequential,sequential,0,2);
    CHECK_WIRE(Hashed,hashed,1,2);
    CHECK_WIRE(UnionDefault,union_default,2,0);
    wide_wire(argv[1]);
    key_frame_errors();
#ifndef __cplusplus
    key_cleanup();
#endif
    TYPE(Align) align=INIT; align.a=0xaa; align.b=UINT64_C(0x0102030405060708);
    CHECK(Align,align,"Align",0,1);
    TYPE(Example) example=INIT;
#ifdef __cplusplus
    example.label="BLUE";
#else
    strcpy(example.label,"BLUE");
#endif
    example.m_nested.m_long=0x12345678; example.m_nested.u=10; example.m_nested.w=20;
    example.x=100; example.y=200;
    CHECK(Example,example,"Example",2,0);
    CHECK_KEY(Example,example,2);
    CHECK_KEY(Nested,example.m_nested,2);
    TYPE(Bounded16) b16=INIT; TYPE(Bounded17) b17=INIT; TYPE(Unbounded) unbounded=INIT;
#ifdef __cplusplus
    b16.text="BLUE"; b17.text="BLUE";
#else
    strcpy(b16.text,"BLUE"); strcpy(b17.text,"BLUE");
#endif
    CHECK(Bounded16,b16,"Bounded16",1,1);
    CHECK(Bounded17,b17,"Bounded17",0,1);
    CHECK(Unbounded,unbounded,"Unbounded",0,1);
#ifdef __cplusplus
    unbounded.text="abcdefghijklmnopqrstuvwxyz";
#else
    unbounded.text=(char *)"abcdefghijklmnopqrstuvwxyz";
#endif
    CHECK(Unbounded,unbounded,"UnboundedLong",0,1);
    TYPE(Seq16) seq16=INIT; TYPE(Seq17) seq17=INIT;
    CHECK(Seq16,seq16,"Seq16",0,1); CHECK(Seq17,seq17,"Seq17",0,1);
    TYPE(UnkeyedNested) inner=INIT; inner.inner.hi=0xaa; inner.inner.lo=0x1234;
    CHECK(UnkeyedNested,inner,"UnkeyedNested",0,1);
    CHECK_KEY(UnkeyedNested,inner,0);
    TYPE(ArrayKey) array=INIT;
    array.values[0].m_long=0x01020304; array.values[1].m_long=0x05060708;
    array.values[0].u=1; array.values[1].w=2;
    CHECK(ArrayKey,array,"ArrayKey",0,0);
    CHECK_KEY(ArrayKey,array,0);
    TYPE(SeqAgg) seq=INIT;
#ifdef __cplusplus
    seq.values.push_back(array.values[0]); seq.values.push_back(array.values[1]);
#else
    seq.values._buffer=array.values; seq.values._length=2; seq.values._maximum=2;
#endif
    CHECK(SeqAgg,seq,"SeqAgg",0,0);
    CHECK_KEY(SeqAgg,seq,0);
    TYPE(WideSeq) wide_seq=INIT;
#ifdef __cplusplus
    wide_seq.values={std::wstring{L'A',(wchar_t)0x1234},std::wstring{}};
#else
    uint16_t wide_elements[2][9]={{'A',0x1234},{0}};
    wide_seq.values._buffer=wide_elements; wide_seq.values._length=2; wide_seq.values._maximum=2;
#endif
    CHECK(WideSeq,wide_seq,"WideSeq",0,1);
    TYPE(UnionKey) choice=INIT;
#ifdef __cplusplus
    choice.selection.small(0xab);
#else
    choice.selection._d=0; choice.selection._u.small=0xab;
#endif
    CHECK(UnionKey,choice,"UnionKey",0,0);
    TYPE(Wide16) wide16=INIT; TYPE(Wide17) wide17=INIT;
#ifdef __cplusplus
    wide16.text.push_back(L'A'); wide16.text.push_back((wchar_t)0x1234);
#else
    wide16.text[0]='A'; wide16.text[1]=0x1234;
#endif
    CHECK(Wide16,wide16,"Wide16",0,1); CHECK(Wide17,wide17,"Wide17",0,1);
    TYPE(Derived) derived=INIT; derived.value=0xaa;
#ifdef __cplusplus
    derived.base_value=0x01020304;
#else
    derived._base.base_value=0x01020304;
#endif
    CHECK(Derived,derived,"Derived",0,1);
    /* A valid key-only XCDR2 mutable payload for the OMG example. This does
     * not depend on the legacy serialize_key mutable framing implementation. */
    uint8_t wire[45],hash[16];
    assert(hex_bytes("000b0000250000001e0000400c000000080000000000002078563412280000400900000005000000424c554500",wire)==45);
    assert(Canonical_Example_compute_key_hash_from_cdr_key_only(wire,sizeof wire,hash)==0);
    assert(!memcmp(hash,lookup("Example")->hash,16));
    memset(hash,0xee,sizeof hash);
#ifdef __cplusplus
    b17.text.assign(13,'Q');
#else
    memset(b17.text,'Q',sizeof b17.text);
#endif
    assert(Canonical_Bounded17_compute_key_hash(&b17,hash)==ZIDL_CDR_INVALID);
    for (size_t i=0;i<16;i++) assert(hash[i]==0xee);
    const ZidlAllocator denying = { NULL,deny_alloc,deny_resize,unexpected_free };
    zidl_cdr_set_allocator(&denying);
    uint8_t fixed[16]; ZidlCdrWriter fixed_writer;
    zidl_cdr_writer_init_fixed(&fixed_writer,fixed,sizeof fixed,ZIDL_XCDR2);
    zidl_cdr_writer_set_byte_order(&fixed_writer,ZIDL_CDR_BE);
    assert(Canonical_Align_serialize_key_holder(&fixed_writer,&align)==0);
    zidl_cdr_compute_key_hash_for_type(fixed_writer.buf,fixed_writer.len,Canonical_Align_KEY_HASH_FORCE_MD5,hash);
    assert(!memcmp(hash,lookup("Align")->hash,16) && denied_allocations==0);
    memset(hash,0xee,sizeof hash);
    assert(Canonical_Align_compute_key_hash(&align,hash)==ZIDL_CDR_OVERFLOW);
    assert(denied_allocations>0);
    for (size_t i=0;i<16;i++) assert(hash[i]==0xee);
    zidl_cdr_set_allocator(NULL);
    puts("canonical key checks passed");
    return 0;
}
