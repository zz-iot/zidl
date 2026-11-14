#include "shapes.hpp"
#include "wire.h"
#include <cassert>
#include <cstdlib>
#include <new>
#include <memory_resource>
#include <cstddef>
static size_t live;
static long budget=-1;
static void *allocate(size_t n){if(budget==0)throw std::bad_alloc();if(budget>0)budget--;void*p=std::malloc(n?n:1);if(!p)throw std::bad_alloc();live++;return p;}
static void release(void*p){if(p){assert(live);live--;std::free(p);}}
void *operator new(size_t n){return allocate(n);} void *operator new[](size_t n){return allocate(n);}
void operator delete(void*p)noexcept{release(p);}void operator delete[](void*p)noexcept{release(p);}
void operator delete(void*p,size_t)noexcept{release(p);}void operator delete[](void*p,size_t)noexcept{release(p);}
struct Resource:std::pmr::memory_resource{void*do_allocate(size_t n,size_t a)override{assert(a<=alignof(std::max_align_t));return ::allocate(n);}void do_deallocate(void*p,size_t,size_t)override{::release(p);}bool do_is_equal(const std::pmr::memory_resource&o)const noexcept override{return this==&o;}};
static int run(const Record*parts,size_t count,int le,int expected,long limit=-1,bool reuse=false){
    uint8_t bytes[1024];size_t n=message(bytes,parts,count,le);ZidlCdrReader r;assert(zidl_cdr_reader_init(&r,bytes,n)==0);
    Admission::Value out{};
    if(reuse){out._d(1);using S=std::remove_cv_t<std::remove_reference_t<decltype(out.text())>>;S old(80,'z');out.text(old);}
    budget=limit;int rc=Admission_Value_deserialize(&r,&out);budget=-1;
    if(expected!=-99)assert(rc==expected);assert(r.pos<=n && r.data_len==n);
    if(rc==0 && out._d()==1)assert(out.text().size()==0 || out.text().size()==64);
    if(rc!=0 && reuse)assert(out._d()==1 && out.text().size()==80 && out.text()[0]=='z');
    return rc;
}
int main(){Resource resource;auto *old=std::pmr::set_default_resource(&resource);for(int le=0;le<2;le++){
    Record disc=word(0,1,le),value=text(20,le),unk=unknown(0,le),mu=unknown(1,le),wrong=text(30,le);
    Record valid[]={disc,value};run(valid,2,le,0);assert(!live);
    Record before[]={value,disc};run(before,2,le,ZIDL_CDR_INVALID);
    run(&disc,1,le,0);run(nullptr,0,le,ZIDL_CDR_INVALID);
    Record dupDisc[]={disc,disc,value};run(dupDisc,3,le,ZIDL_CDR_INVALID);
    Record lateDisc[]={disc,value,disc};run(lateDisc,3,le,ZIDL_CDR_INVALID,-1,true);
    Record dup[]={disc,value,value};run(dup,3,le,ZIDL_CDR_INVALID,-1,true);
    Record mismatch[]={disc,wrong};run(mismatch,2,le,ZIDL_CDR_INVALID);
    Record extra[]={unk,disc,unk,value,unk};run(extra,5,le,0);
    Record umu[]={disc,value,mu};run(umu,3,le,ZIDL_CDR_INVALID,-1,true);
    Record early[]={mu,disc,value};run(early,3,le,ZIDL_CDR_INVALID);
    Record oversized=disc;oversized.len=12;u32(oversized.bytes,0xb0000000u,le);Record extent[]={oversized,value};run(extent,2,le,ZIDL_CDR_INVALID);
    for(long i=0;;i++){int rc=run(valid,2,le,-99,i,true);assert(!live);if(rc==0)break;assert(rc==ZIDL_CDR_OVERFLOW && i<32);}
    Record seq[]={word(0,99,le),words(30,le)};for(long i=0;;i++){int rc=run(seq,2,le,-99,i,true);assert(!live);if(rc==0)break;assert(rc==ZIDL_CDR_OVERFLOW && i<32);}
    uint8_t bytes[1024];size_t n=message(bytes,valid,2,le);for(size_t cut=4;cut<n;cut++){Admission::Value out{};ZidlCdrReader r;assert(zidl_cdr_reader_init(&r,bytes,cut)==0);assert(Admission_Value_deserialize(&r,&out)!=0 && r.pos<=cut);}assert(!live);
    Record fd[]={word(0,99,le),text(40,le)};n=message(bytes,fd,2,le);{Admission::DefaultFirst out{};ZidlCdrReader r;assert(zidl_cdr_reader_init(&r,bytes,n)==0 && Admission_DefaultFirst_deserialize(&r,&out)==0 && out._d()==99 && out.text().size()==64);}
    Record ed[]={word(0,1,le),text(20,le)};n=message(bytes,ed,2,le);{Admission::EnumValue out{};ZidlCdrReader r;assert(zidl_cdr_reader_init(&r,bytes,n)==0 && Admission_EnumValue_deserialize(&r,&out)==0 && out._d()==Admission::Tag::One);}
    assert(!live);
 }std::pmr::set_default_resource(old);return 0;}
