#include "zidl_cdr.h"
#include <string.h>
#define REQUIRE(x) do { if (!(x)) return __LINE__; } while (0)

int fixed_external_contract(void) {
    const uint8_t expected[] = {0x10,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x01,0x98,0x84,0x62,0x48,0x38,0x65,0x6c};
    int version, order, mode;
    for (version=1;version<=2;++version) for (order=0;order<2;++order) for (mode=0;mode<3;++mode) {
        uint8_t storage[64];
        ZidlCdrWriter w;
        if (mode==0) REQUIRE(zidl_cdr_writer_init(&w,version)==0);
        else if (mode==1) zidl_cdr_writer_init_fixed(&w,storage,sizeof storage,version);
        else zidl_cdr_writer_init_counting(&w,version);
        zidl_cdr_writer_set_byte_order(&w,order);
        REQUIRE(zidl_cdr_write_encap(&w)==0);
        REQUIRE(zidl_cdr_write_u8(&w,0xa5)==0);
        REQUIRE(zidl_cdr_write_fixed(&w,31,0,1e30)==0);
        REQUIRE(w.len==21 && w.pos==17);
        if (mode!=2) {
            ZidlCdrReader r;
            double value=0;
            uint8_t marker=0;
            REQUIRE(memcmp(w.buf+5,expected,sizeof expected)==0);
            REQUIRE(zidl_cdr_reader_init(&r,w.buf,w.len)==0);
            REQUIRE(zidl_cdr_read_u8(&r,&marker)==0 && marker==0xa5);
            REQUIRE(zidl_cdr_read_fixed(&r,31,0,&value)==0 && value==1e30);
            REQUIRE(r.pos==21);
            w.buf[20]=0x6b;
            r.pos=5; value=42;
            REQUIRE(zidl_cdr_read_fixed(&r,31,0,&value)==ZIDL_CDR_INVALID && value==42);
        }
        REQUIRE(zidl_cdr_write_fixed(&w,255,0,1)==ZIDL_CDR_INVALID);
        REQUIRE(w.len==21 && w.pos==17);
        zidl_cdr_writer_deinit(&w);
    }
    return 0;
}
