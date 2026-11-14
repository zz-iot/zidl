extern "C" {
#include "maps.h"
}
#include <cassert>
int main() {
    zidl_map_int32_t_int32_t_map_entry entries[]={{1,42}};
    Maps_Sample source{}; source.values={1,1,entries,false}; source.tail=7;
    uint8_t bytes[128];ZidlCdrWriter w;
    zidl_cdr_writer_init_fixed(&w,bytes,sizeof bytes,ZIDL_XCDR2);
    assert(zidl_cdr_write_encap(&w)==0 && Maps_Sample_serialize(&w,&source)==0);
    Maps_Sample out{};ZidlCdrReader r;
    assert(zidl_cdr_reader_init(&r,bytes,w.len)==0 && Maps_Sample_deserialize(&r,&out)==0);
    assert(out.values._length==1 && out.values._buffer[0].value==42 && out.tail==7);
    Maps_Sample_free(&out);Maps_Sample_free(&out);
    zidl_map_string_string_map_entry strings[]={{const_cast<char*>("name"),const_cast<char*>("value")}};
    Maps_Owned owning{};owning.values={1,1,strings,false};
    zidl_cdr_writer_init_fixed(&w,bytes,sizeof bytes,ZIDL_XCDR2);
    assert(zidl_cdr_write_encap(&w)==0 && Maps_Owned_serialize(&w,&owning)==0);
    Maps_Owned decoded{};
    assert(zidl_cdr_reader_init(&r,bytes,w.len)==0 && Maps_Owned_deserialize(&r,&decoded)==0);
    assert(decoded.values._length==1 && decoded.values._buffer[0].value[0]=='v');Maps_Owned_free(&decoded);

}
