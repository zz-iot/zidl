#include "maps.h"
#include <assert.h>
#include <string.h>
#include <stdlib.h>
static size_t live, calls;
static int fail;
static void *allocate(void *ctx, size_t n, size_t a) { (void)ctx; (void)a; calls++; if(fail) return NULL; void *p=malloc(n); if(p) live++; return p; }
static bool resize(void *ctx,void *p,size_t a,size_t b,size_t c) { (void)ctx;(void)p;(void)a;(void)b;(void)c; return false; }
static void release(void *ctx,void *p,size_t n,size_t a) { (void)ctx;(void)n;(void)a; if(p) {assert(live);live--;free(p);} }
int main(void) {
    ZidlAllocator alloc={NULL,allocate,resize,release}; zidl_cdr_set_allocator(&alloc);
    zidl_map_int32_t_int32_t_map_entry entries[]={{1,11},{2,22}};
    Maps_Sample value={{2,2,entries,false},42};
    for(int version=ZIDL_XCDR1;version<=ZIDL_XCDR2;version++) for(int order=ZIDL_CDR_LE;order<=ZIDL_CDR_BE;order++) {
        uint8_t bytes[128]; ZidlCdrWriter w;
        zidl_cdr_writer_init_fixed(&w,bytes,sizeof bytes,version);zidl_cdr_writer_set_byte_order(&w,order);
        assert(zidl_cdr_write_encap(&w)==0);assert(Maps_Sample_serialize(&w,&value)==0);
        /* Primitive maps are count + key/value pairs, without a collection DHEADER. */
        const uint8_t le[]={2,0,0,0,1,0,0,0,11,0,0,0,2,0,0,0,22,0,0,0,42,0,0,0};
        const uint8_t be[]={0,0,0,2,0,0,0,1,0,0,0,11,0,0,0,2,0,0,0,22,0,0,0,42};
        assert(w.len==28 && !memcmp(bytes+4,order==ZIDL_CDR_LE?le:be,24));
        for(size_t cut=4;cut<=w.len;cut++) {
            Maps_Sample out={0}; ZidlCdrReader r; size_t before=calls;
            assert(zidl_cdr_reader_init(&r,bytes,cut)==0);int rc=Maps_Sample_deserialize(&r,&out);
            if(cut<w.len) assert(rc!=0);else {assert(rc==0 && out.tail==42 && out.values._length==2);assert(!memcmp(entries,out.values._buffer,sizeof entries));}
            if(cut<24) assert(calls==before); /* Entry extent validated before allocation. */
            Maps_Sample_free(&out);Maps_Sample_free(&out);assert(!live);
        }
        fail=1; Maps_Sample out={0}; ZidlCdrReader r;assert(zidl_cdr_reader_init(&r,bytes,w.len)==0);
        assert(Maps_Sample_deserialize(&r,&out)==ZIDL_CDR_OVERFLOW);Maps_Sample_free(&out);Maps_Sample_free(&out);assert(!live);fail=0;
        /* Duplicate serialized key is rejected and partial output stays freeable. */
        memcpy(bytes+16,bytes+8,4);memset(&out,0,sizeof out);assert(zidl_cdr_reader_init(&r,bytes,w.len)==0);
        assert(Maps_Sample_deserialize(&r,&out)==ZIDL_CDR_INVALID);Maps_Sample_free(&out);Maps_Sample_free(&out);assert(!live);
        entries[1].key=1;zidl_cdr_writer_init_counting(&w,version);assert(Maps_Sample_serialize(&w,&value)==ZIDL_CDR_INVALID);entries[1].key=2;
        memset(&out,0,sizeof out); size_t before=calls;
        if(order==ZIDL_CDR_LE) { bytes[4]=4;bytes[5]=bytes[6]=bytes[7]=0; }
        else {bytes[4]=bytes[5]=bytes[6]=0;bytes[7]=4;}
        assert(zidl_cdr_reader_init(&r,bytes,28)==0 && Maps_Sample_deserialize(&r,&out)==ZIDL_CDR_INVALID);
        assert(calls==before);Maps_Sample_free(&out);
        value.values._maximum=4;
        value.values._length=4;zidl_cdr_writer_init_counting(&w,version);assert(Maps_Sample_serialize(&w,&value)==ZIDL_CDR_INVALID);value.values._length=2;value.values._maximum=2;
        value.values._length=0;zidl_cdr_writer_init_fixed(&w,bytes,sizeof bytes,version);zidl_cdr_writer_set_byte_order(&w,order);
        assert(zidl_cdr_write_encap(&w)==0 && Maps_Sample_serialize(&w,&value)==0 && w.len==12);
        memset(&out,0,sizeof out);before=calls;assert(zidl_cdr_reader_init(&r,bytes,w.len)==0 && Maps_Sample_deserialize(&r,&out)==0);
        assert(calls==before && out.values._length==0 && out.tail==42);Maps_Sample_free(&out);value.values._length=2;
    }
    for(int version=ZIDL_XCDR1;version<=ZIDL_XCDR2;version++) for(int order=ZIDL_CDR_LE;order<=ZIDL_CDR_BE;order++) {
        zidl_map_uint8_t_uint64_t_map_entry pair[]={{1,UINT64_C(0x0102030405060708)},{2,UINT64_C(0x1112131415161718)}};
        Maps_Mixed mixed={{2,2,pair,false}}, decoded={0};
        uint8_t bytes[128]; ZidlCdrWriter w; ZidlCdrReader r;
        zidl_cdr_writer_init_fixed(&w,bytes,sizeof bytes,version);zidl_cdr_writer_set_byte_order(&w,order);
        assert(zidl_cdr_write_encap(&w)==0 && Maps_Mixed_serialize(&w,&mixed)==0);
        assert(w.len==(version==ZIDL_XCDR1?36u:32u));
        const uint8_t firstLE[]={8,7,6,5,4,3,2,1},firstBE[]={1,2,3,4,5,6,7,8};
        assert(bytes[8]==1 && bytes[20]==2 && !memcmp(bytes+12,order==ZIDL_CDR_LE?firstLE:firstBE,8));
        assert(zidl_cdr_reader_init(&r,bytes,w.len)==0 && Maps_Mixed_deserialize(&r,&decoded)==0);
        assert(decoded.values._length==2 && decoded.values._buffer[1].value==pair[1].value);
        Maps_Mixed_free(&decoded);assert(!live);
        Maps_Table tables[]={value.values};Maps_Nested nested={{1,1,tables,false}}, out={0};
        zidl_cdr_writer_init_fixed(&w,bytes,sizeof bytes,version);zidl_cdr_writer_set_byte_order(&w,order);
        assert(zidl_cdr_write_encap(&w)==0 && Maps_Nested_serialize(&w,&nested)==0);
        assert(zidl_cdr_reader_init(&r,bytes,w.len)==0 && Maps_Nested_deserialize(&r,&out)==0);
        assert(out.values._buffer[0]._length==2); Maps_Nested_free(&out);assert(!live);
    }
    Maps_Sample_free(&value);assert(!live);zidl_cdr_set_allocator(NULL);return 0;
}
