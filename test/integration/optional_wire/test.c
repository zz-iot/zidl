#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef __cplusplus
#include "shapes.hpp"
#define TYPE(n) OptionalWire::n
#define INIT {}
#define FREE(n, v) ((void)0)
#else
#include "shapes.h"
#define TYPE(n) OptionalWire_##n
#define INIT {0}
#define FREE(n, v) OptionalWire_##n##_free(&(v))
#endif
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

#ifndef __cplusplus
#define FAILURES(N,input,size,key) do { \
    for (int left=0;left<6;++left) { \
        TYPE(N) partial=INIT; ZidlCdrReader reader; \
        assert(zidl_cdr_reader_init(&reader,input,size)==0); allocations_left=left; \
        if (key) (void)OptionalWire_##N##_deserialize_key_value(&reader,&partial); \
        else (void)OptionalWire_##N##_deserialize(&reader,&partial); \
        allocations_left=-1; FREE(N,partial); assert(live_count==0); \
    } \
} while(0)
#else
#define FAILURES(N,input,size,key) ((void)0)
#endif
static unsigned nibble(char c) { return c <= '9' ? (unsigned)(c-'0') : (unsigned)(c-'a'+10); }
static size_t unhex(const char *s, uint8_t *p) {
    size_t n = strlen(s)/2;
    for (size_t i=0; i<n; ++i) p[i]=(uint8_t)((nibble(s[2*i])<<4)|nibble(s[2*i+1]));
    return n;
}
static void init_values(TYPE(Values) *v, int present) {
    v->tail=UINT64_C(0x1122334455667788);
    if (!present) return;
#ifdef __cplusplus
    v->number=UINT64_C(0x0102030405060708); v->text="";
    v->numbers.emplace(); v->numbers->values[0]=42; v->numbers->values[1]=43;
    v->texts=std::vector<std::string>{"blue","orange"};
#else
    static char *texts[]={"blue","orange"};
    v->_present=15; v->number=UINT64_C(0x0102030405060708); v->text=(char *)"";
    v->numbers.values[0]=42; v->numbers.values[1]=43;
    v->texts._buffer=texts; v->texts._length=v->texts._maximum=2;
#endif
}
static void init_derived(TYPE(Derived) *v, int present) {
    v->tail=UINT64_C(0x1122334455667788);
    if (!present) return;
#ifdef __cplusplus
    v->item.emplace(); v->item->prefix=0xa5;
    v->item->value=UINT64_C(0x0102030405060708); v->item->tail=99; v->extra="extra";
#else
    v->_base._present=1; v->_present=1; v->_base.item._present=1;
    v->_base.item.prefix=0xa5; v->_base.item.value=UINT64_C(0x0102030405060708);
    v->_base.item.tail=99; v->extra=(char *)"extra";
#endif
}
static void check_values(const TYPE(Values) *v, int present) {
#ifdef __cplusplus
    assert(v->number.has_value()==(bool)present && v->text.has_value()==(bool)present);
    assert(v->numbers.has_value()==(bool)present && v->texts.has_value()==(bool)present);
    if (present) {
        assert(*v->number==UINT64_C(0x0102030405060708) && v->text->empty());
        assert(v->numbers->values[0]==42 && v->numbers->values[1]==43);
        assert(v->texts->size()==2 && (*v->texts)[0]=="blue" && (*v->texts)[1]=="orange");
    }
#else
    assert(v->_present==(present ? 15u : 0u));
    if (present) {
        assert(v->number==UINT64_C(0x0102030405060708) && strcmp(v->text,"")==0);
        assert(v->numbers.values[0]==42 && v->numbers.values[1]==43);
        assert(v->texts._length==2 && strcmp(v->texts._buffer[0],"blue")==0 && strcmp(v->texts._buffer[1],"orange")==0);
    }
#endif
}
static void check_derived(const TYPE(Derived) *v, int present) {
#ifdef __cplusplus
    assert(v->item.has_value()==(bool)present && v->extra.has_value()==(bool)present);
    if (present) assert(v->item->prefix==0xa5 && *v->item->value==UINT64_C(0x0102030405060708) && v->item->tail==99 && *v->extra=="extra");
#else
    assert(v->_base._present==(unsigned)present && v->_present==(unsigned)present);
    if (present) assert(v->_base.item.prefix==0xa5 && v->_base.item._present==1 && v->_base.item.value==UINT64_C(0x0102030405060708) && v->_base.item.tail==99 && strcmp(v->extra,"extra")==0);
#endif
}
#define check_Values_alias check_values
#define check_Derived_alias check_derived
#define CHECK_TYPE(N) do { \
    TYPE(N) value=INIT; init_##N##_alias(&value,present); \
    for (int key=0;key<2;++key) { \
        for (size_t cap=4;cap<len;++cap) { \
            uint8_t actual[1024]; ZidlCdrWriter w; \
            zidl_cdr_writer_init_fixed(&w,actual,cap,version); zidl_cdr_writer_set_byte_order(&w,order); \
            assert(zidl_cdr_write_encap_kind(&w,strcmp(name,"Derived")==0 ? ZIDL_EXT_APPENDABLE : ZIDL_EXT_FINAL)==0); \
            assert((key ? OptionalWire_##N##_serialize_key_value(&w,&value) : OptionalWire_##N##_serialize(&w,&value))==ZIDL_CDR_OVERFLOW); \
            assert(w.len<=cap && w.pos==w.len-4); \
        } \
        for (int mode=0;mode<3;++mode) { \
            uint8_t actual[1024]; ZidlCdrWriter w; \
            if (mode==0) assert(zidl_cdr_writer_init(&w,version)==0); \
            else if (mode==1) zidl_cdr_writer_init_fixed(&w,actual,sizeof actual,version); \
            else zidl_cdr_writer_init_counting(&w,version); \
            zidl_cdr_writer_set_byte_order(&w,order); \
            assert(zidl_cdr_write_encap_kind(&w,strcmp(name,"Derived")==0 ? ZIDL_EXT_APPENDABLE : ZIDL_EXT_FINAL)==0); \
            assert((key ? OptionalWire_##N##_serialize_key_value(&w,&value) : OptionalWire_##N##_serialize(&w,&value))==0); \
            assert(w.len==len); if (mode!=2) assert(memcmp(w.buf,bytes,len)==0); \
            if (mode==0) zidl_cdr_writer_deinit(&w); \
        } \
        for (int compact=0;compact<2;++compact) { \
            const uint8_t *input=compact ? short_bytes : bytes; size_t size=compact ? short_len : len; \
            ZidlCdrReader r; TYPE(N) out=INIT; \
            assert(zidl_cdr_reader_init(&r,input,size)==0); \
            assert((key ? OptionalWire_##N##_deserialize_key_value(&r,&out) : OptionalWire_##N##_deserialize(&r,&out))==0); \
            assert(r.pos==size && r.data_len==size && r.data==input); \
            assert(out.tail==value.tail); check_##N##_alias(&out,present); FREE(N,out); \
            FAILURES(N,input,size,key); \
            assert(zidl_cdr_reader_init(&r,input,size)==0); \
            assert(OptionalWire_##N##_skip(&r)==0 && r.pos==size); \
            for (size_t n=4;n<size;++n) { \
                TYPE(N) partial=INIT; assert(zidl_cdr_reader_init(&r,input,n)==0); \
                assert((key ? OptionalWire_##N##_deserialize_key_value(&r,&partial) : OptionalWire_##N##_deserialize(&r,&partial))!=0); \
                assert(r.data==input && r.data_len==n && r.pos<=n); FREE(N,partial); \
            } \
        } \
    } \
} while(0)
#define init_Values_alias init_values
#define init_Derived_alias init_derived
int main(int argc, char **argv) {
#ifndef __cplusplus
    ZidlAllocator allocator={NULL,allocate,resize_block,release}; zidl_cdr_set_allocator(&allocator);
#endif
    assert(argc==2); FILE *f=fopen(argv[1],"r"); assert(f);
    char name[32], full[2048], compact[2048]; int present,version,order; size_t count=0;
    while (fscanf(f,"%31s %d %d %d %2047s %2047s",name,&present,&version,&order,full,compact)==6) {
        uint8_t bytes[1024],short_bytes[1024]; size_t len=unhex(full,bytes),short_len=unhex(compact,short_bytes);
        if (strcmp(name,"Values")==0) CHECK_TYPE(Values); else CHECK_TYPE(Derived);
        ++count;
    }
#ifndef __cplusplus
    assert(live_count==0); zidl_cdr_set_allocator(NULL);
#endif
    fclose(f); assert(count==16); puts("optional wire vectors passed"); return 0;
}
