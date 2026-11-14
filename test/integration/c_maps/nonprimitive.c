#include "maps.h"
#include <assert.h>
#include <stdlib.h>
#include <string.h>
static size_t live,attempts;
static long budget=-1;
static void *allocate(void *ctx,size_t n,size_t a) {(void)ctx;(void)a;attempts++;if(budget==0)return NULL;if(budget>0)budget--;void *p=malloc(n);if(p)live++;return p;}
static bool resize(void *c,void *p,size_t a,size_t b,size_t d) {(void)c;(void)p;(void)a;(void)b;(void)d;return false;}
static void release(void *c,void *p,size_t n,size_t a) {(void)c;(void)n;(void)a;if(p){assert(live);live--;free(p);}}
#define CHECK(TYPE, VALUE, TRAILING, ASSERTION) do { \
    uint8_t bytes[2048];ZidlCdrWriter w; \
    zidl_cdr_writer_init_fixed(&w,bytes,sizeof bytes,version);zidl_cdr_writer_set_byte_order(&w,order); \
    assert(zidl_cdr_write_encap(&w)==0 && TYPE##_serialize(&w,&VALUE)==0); \
    ZidlCdrReader r;assert(zidl_cdr_reader_init(&r,bytes,w.len)==0 && TYPE##_skip(&r)==0 && r.pos==w.len); \
    for(size_t cut=4;cut<=w.len;cut++){ TYPE out={0};size_t before=attempts;assert(zidl_cdr_reader_init(&r,bytes,cut)==0);int rc=TYPE##_deserialize(&r,&out); \
      if(cut<w.len) assert(rc!=0); else {assert(rc==0 && r.pos==w.len);ASSERTION;} \
      if(cut<w.len-TRAILING && version==ZIDL_XCDR2) assert(attempts==before);TYPE##_free(&out);assert(!live); } \
    for(long limit=0;;limit++){budget=limit;TYPE out={0};assert(zidl_cdr_reader_init(&r,bytes,w.len)==0);int rc=TYPE##_deserialize(&r,&out);TYPE##_free(&out);assert(!live);budget=-1;if(rc==0)break;assert(limit<100);} \
}while(0)

int main(void){
    const ZidlAllocator alloc={NULL,allocate,resize,release};zidl_cdr_set_allocator(&alloc);
    zidl_map_string_int32_t_entry dictEntries[]={{(char*)"A",11},{(char*)"B",22}};
    Maps_Dictionary dictionary={{2,2,dictEntries,false},42};
    zidl_map_string_string_entry ownedEntries[]={{(char*)"key",(char*)"value"},{(char*)"two",(char*)"other"}};
    Maps_Owned owned={{2,2,ownedEntries,false}};
    uint16_t wideKeys[][2]={{0x1234,0},{0x4567,0}};
    zidl_map_wstring_string_entry wideEntries[]={{wideKeys[0],(char*)"value"},{wideKeys[1],(char*)"other"}};
    Maps_WideOwned wide={{2,2,wideEntries,false}};
    zidl_map_string4_wstring2_entry boundedEntries[]={{{'A',0},{0x1234,0}},{ {'B',0},{0x4567,0}}};
    Maps_Bounded bounded={{2,2,boundedEntries,false}};
    zidl_map_int32_t_Maps_Person_entry peopleEntries[]={{1,{(char*)"name"}}};
    Maps_People people={{1,1,peopleEntries,false}};
    zidl_map_int32_t_Maps_DictionaryTable_entry nestedEntries[]={{7,{2,2,dictEntries,false}}};
    Maps_NestedOwned nested={{1,1,nestedEntries,false}};
    zidl_map_int32_t_Maps_Row_entry rowEntries[]={{7,{11,22}}};Maps_Rows rows={{1,1,rowEntries,false}};
    zidl_map_int32_t_Maps_Choice_entry choiceEntries[]={{7,{0,{.text=(char*)"choice"}}}};Maps_Choices choices={{1,1,choiceEntries,false}};
    char *items[]={(char*)"first",(char*)"second"};
    zidl_map_int32_t_string_seq_entry listEntries[]={{7,{2,2,items,false}}};Maps_Lists lists={{1,1,listEntries,false}};
    for(int version=ZIDL_XCDR1;version<=ZIDL_XCDR2;version++)for(int order=ZIDL_CDR_LE;order<=ZIDL_CDR_BE;order++){
        uint8_t bytes[128];ZidlCdrWriter w;zidl_cdr_writer_init_fixed(&w,bytes,sizeof bytes,version);zidl_cdr_writer_set_byte_order(&w,order);
        assert(zidl_cdr_write_encap(&w)==0 && Maps_Dictionary_serialize(&w,&dictionary)==0 && w.len==(version==ZIDL_XCDR2?40u:36u));
        /* OMG DDSXTY14-72 corrects rule 15: DHEADER, count, then pairs. */
        const uint8_t le[]={28,0,0,0,2,0,0,0,2,0,0,0,'A',0,0,0,11,0,0,0,2,0,0,0,'B',0,0,0,22,0,0,0,42,0,0,0};
        const uint8_t be[]={0,0,0,28,0,0,0,2,0,0,0,2,'A',0,0,0,0,0,0,11,0,0,0,2,'B',0,0,0,0,0,0,22,0,0,0,42};
        const uint8_t *expected=order==ZIDL_CDR_LE?le:be;
        assert(!memcmp(bytes+4,expected+(version==ZIDL_XCDR2?0:4),version==ZIDL_XCDR2?36:32));
        CHECK(Maps_Dictionary,dictionary,4,assert(out.values._length==2 && !strcmp(out.values._buffer[1].key,"B") && out.tail==42));
        CHECK(Maps_Owned,owned,0,assert(out.values._length==2 && !strcmp(out.values._buffer[0].value,"value")));
        CHECK(Maps_WideOwned,wide,0,assert(out.values._length==2 && out.values._buffer[1].key[0]==0x4567));
        CHECK(Maps_Bounded,bounded,0,assert(out.values._length==2 && out.values._buffer[1].value[0]==0x4567));
        CHECK(Maps_People,people,0,assert(out.values._length==1 && !strcmp(out.values._buffer[0].value.name,"name")));
        CHECK(Maps_NestedOwned,nested,0,assert(out.values._length==1 && out.values._buffer[0].value._length==2));
        zidl_cdr_writer_init_fixed(&w,bytes,sizeof bytes,version);zidl_cdr_writer_set_byte_order(&w,order);
        assert(zidl_cdr_write_encap(&w)==0 && Maps_Owned_serialize(&w,&owned)==0);
        size_t delta=version==ZIDL_XCDR2?4u:0u;memcpy(bytes+32+delta,bytes+12+delta,4);Maps_Owned duplicate={0};ZidlCdrReader r;
        assert(zidl_cdr_reader_init(&r,bytes,w.len)==0 && Maps_Owned_deserialize(&r,&duplicate)==ZIDL_CDR_INVALID);
        Maps_Owned_free(&duplicate);assert(!live);
        if(version==ZIDL_XCDR2){
            size_t before=attempts;zidl_cdr_writer_init_fixed(&w,bytes,sizeof bytes,version);zidl_cdr_writer_set_byte_order(&w,order);
            assert(zidl_cdr_write_encap(&w)==0 && Maps_Owned_serialize(&w,&owned)==0);
            bytes[order==ZIDL_CDR_LE?4:7]--;memset(&duplicate,0,sizeof duplicate);
            assert(zidl_cdr_reader_init(&r,bytes,w.len)==0 && Maps_Owned_deserialize(&r,&duplicate)!=0);
            assert(attempts==before);Maps_Owned_free(&duplicate);assert(!live);
        }
        CHECK(Maps_Rows,rows,0,assert(out.values._length==1 && out.values._buffer[0].value[1]==22));
        CHECK(Maps_Choices,choices,0,assert(out.values._length==1 && !strcmp(out.values._buffer[0].value._u.text,"choice")));
        CHECK(Maps_Lists,lists,0,assert(out.values._length==1 && out.values._buffer[0].value._length==2));
        dictionary.values._length=0;zidl_cdr_writer_init_fixed(&w,bytes,sizeof bytes,version);zidl_cdr_writer_set_byte_order(&w,order);
        assert(zidl_cdr_write_encap(&w)==0 && Maps_Dictionary_serialize(&w,&dictionary)==0 && w.len==(version==ZIDL_XCDR2?16u:12u));
        Maps_Dictionary empty={0};assert(zidl_cdr_reader_init(&r,bytes,w.len)==0 && Maps_Dictionary_deserialize(&r,&empty)==0);
        assert(empty.values._length==0 && empty.tail==42);Maps_DictionaryTable_free(&empty.values);Maps_Dictionary_free(&empty);assert(!live);dictionary.values._length=2;
        wideKeys[1][0]=wideKeys[0][0];zidl_cdr_writer_init_counting(&w,version);assert(Maps_WideOwned_serialize(&w,&wide)==ZIDL_CDR_INVALID);wideKeys[1][0]=0x4567;
        ownedEntries[1].key=ownedEntries[0].key;zidl_cdr_writer_init_counting(&w,version);assert(Maps_Owned_serialize(&w,&owned)==ZIDL_CDR_INVALID);ownedEntries[1].key=(char*)"two";
    }
    zidl_cdr_set_allocator(NULL);return 0;
}
