#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "shapes.h"
static size_t live;
static long budget=-1;
static void *allocate(void *c,size_t n,size_t a){(void)c;(void)a;if(budget==0)return NULL;if(budget>0)budget--;void*p=malloc(n);if(p)live++;return p;}
static bool resize(void*c,void*p,size_t a,size_t b,size_t d){(void)c;(void)p;(void)a;(void)b;(void)d;return false;}
static void release(void*c,void*p,size_t n,size_t a){(void)c;(void)n;(void)a;if(p){assert(live);live--;free(p);}}
#include "wire.h"
static int run(const Record*parts,size_t count,int le,int expected){uint8_t bytes[1024];size_t n=message(bytes,parts,count,le);ZidlCdrReader r;assert(zidl_cdr_reader_init(&r,bytes,n)==0);Admission_Value out={0};int rc=Admission_Value_deserialize(&r,&out);if(expected!=-99)assert(rc==expected);assert(r.pos<=n && r.data_len==n);if(rc==0 && out._d==1 && out._u.text)assert(strlen(out._u.text)==64);Admission_Value_free(&out);assert(!live);return rc;}
int main(void){ZidlAllocator a={NULL,allocate,resize,release};zidl_cdr_set_allocator(&a);for(int le=0;le<2;le++){
    Record disc=word(0,1,le), value=text(20,le), unk=unknown(0,le), mu=unknown(1,le), mismatch=text(30,le);
    Record valid[]={disc,value};assert(run(valid,2,le,0)==0);
    Record before[]={value,disc};run(before,2,le,ZIDL_CDR_INVALID);
    run(&disc,1,le,0);run(NULL,0,le,ZIDL_CDR_INVALID);
    Record duplicateDisc[]={disc,disc,value};run(duplicateDisc,3,le,ZIDL_CDR_INVALID);
    Record lateDisc[]={disc,value,disc};run(lateDisc,3,le,ZIDL_CDR_INVALID);
    Record duplicate[]={disc,value,value};run(duplicate,3,le,ZIDL_CDR_INVALID);
    Record wrong[]={disc,mismatch};run(wrong,2,le,ZIDL_CDR_INVALID);
    Record extra[]={unk,disc,unk,value,unk};run(extra,5,le,0);
    Record unknownMu[]={disc,value,mu};run(unknownMu,3,le,ZIDL_CDR_INVALID);
    Record unknownFirst[]={mu,disc,value};run(unknownFirst,3,le,ZIDL_CDR_INVALID);
    Record oversized=disc;oversized.len=12;u32(oversized.bytes,0xb0000000u,le);Record badExtent[]={oversized,value};run(badExtent,2,le,ZIDL_CDR_INVALID);
    uint8_t bytes[1024];size_t n=message(bytes,valid,2,le);for(size_t cut=4;cut<n;cut++){Admission_Value out={0};ZidlCdrReader r;assert(zidl_cdr_reader_init(&r,bytes,cut)==0);assert(Admission_Value_deserialize(&r,&out)!=0 && r.pos<=cut);Admission_Value_free(&out);assert(!live);}
    for(long limit=0;;limit++){budget=limit;int rc=run(valid,2,le,-99);budget=-1;if(rc==0)break;assert(rc==ZIDL_CDR_OVERFLOW && limit<16);}
    Record sequence[]={word(0,99,le),words(30,le)};run(sequence,2,le,0);
    for(long limit=0;;limit++){budget=limit;int rc=run(sequence,2,le,-99);budget=-1;if(rc==0)break;assert(rc==ZIDL_CDR_OVERFLOW && limit<16);}
    Record lateSequence[]={sequence[0],sequence[1],disc};run(lateSequence,3,le,ZIDL_CDR_INVALID);
    Admission_NoDefault no={0};Record only=word(0,99,le);n=message(bytes,&only,1,le);ZidlCdrReader r;assert(zidl_cdr_reader_init(&r,bytes,n)==0 && Admission_NoDefault_deserialize(&r,&no)==0 && no._d==99);
    Record fd[]={word(0,99,le),text(40,le)};n=message(bytes,fd,2,le);Admission_DefaultFirst first={0};assert(zidl_cdr_reader_init(&r,bytes,n)==0 && Admission_DefaultFirst_deserialize(&r,&first)==0 && first._d==99 && strlen(first._u.text)==64);Admission_DefaultFirst_free(&first);assert(!live);
    Record ed[]={word(0,1,le),text(20,le)};n=message(bytes,ed,2,le);Admission_EnumValue e={0};assert(zidl_cdr_reader_init(&r,bytes,n)==0 && Admission_EnumValue_deserialize(&r,&e)==0 && e._d==(Admission_Tag)1);Admission_EnumValue_free(&e);assert(!live);
 }zidl_cdr_set_allocator(NULL);return 0;}
