#include <stddef.h>
#include <stdio.h>
#include "zidl_cdr.h"
#define FIELD(T, f) printf("%zu ", offsetof(T, f))
int main(void) {
    printf("%zu %zu ", sizeof(ZidlCdrWriter), _Alignof(ZidlCdrWriter));
    FIELD(ZidlCdrWriter, buf); FIELD(ZidlCdrWriter, cap);
    FIELD(ZidlCdrWriter, len); FIELD(ZidlCdrWriter, pos);
    FIELD(ZidlCdrWriter, xcdr_version); FIELD(ZidlCdrWriter, byte_order);
    FIELD(ZidlCdrWriter, grow_fn);
    printf("%zu %zu ", sizeof(ZidlCdrReader), _Alignof(ZidlCdrReader));
    FIELD(ZidlCdrReader, data); FIELD(ZidlCdrReader, data_len);
    FIELD(ZidlCdrReader, pos); FIELD(ZidlCdrReader, byte_order);
    FIELD(ZidlCdrReader, xcdr_version); FIELD(ZidlCdrReader, is_pl_cdr);
    puts(""); return 0;
}
