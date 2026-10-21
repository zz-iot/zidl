#include "zidl_typesupport.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <dlfcn.h>

static const ZidlTsType *find(const ZidlTsLibrary *lib, const char *name) {
    size_t n = strlen(name);
    for (uint64_t i = 0; i < lib->type_count; ++i)
        if (lib->types[i].name.size == n && !memcmp(lib->types[i].name.data, name, n)) return &lib->types[i];
    return NULL;
}
int main(int argc, char **argv) {
    assert(argc == 4);
    void *handles[3];
    const ZidlTsLibrary *libs[3];
    for (unsigned i = 0; i < 3; ++i) {
        handles[i] = dlopen(argv[i + 1], RTLD_NOW | RTLD_LOCAL);
        if (!handles[i]) { fprintf(stderr, "%s\n", dlerror()); return 1; }
        ZidlTsQuery query = (ZidlTsQuery)dlsym(handles[i], "zidl_typesupport_query");
        assert(query);
        assert(query(ZIDL_TS_ABI_MAJOR, NULL) == ZIDL_TS_INVALID_ARGUMENT);
        libs[i] = (void *)1;
        assert(query(1, &libs[i]) == ZIDL_TS_ABI_MISMATCH && libs[i] == NULL);
        assert(query(ZIDL_TS_ABI_MAJOR, &libs[i]) == ZIDL_TS_OK);
        assert(libs[i]->descriptor_size == sizeof(ZidlTsLibrary));
        assert(libs[i]->abi_major == ZIDL_TS_ABI_MAJOR);
        for (uint64_t j = 0; j < libs[i]->type_count; ++j)
            assert(libs[i]->types[j].descriptor_size == sizeof(ZidlTsType));
        for (uint64_t j = 0; j < libs[i]->object_count; ++j)
            assert(libs[i]->objects[j].descriptor_size == sizeof(ZidlTsObject));
    }
    const ZidlTsType *a = find(libs[0], "Shared::Reading");
    const ZidlTsType *b = find(libs[1], "Shared::Reading");
    const ZidlTsType *conflict = find(libs[2], "Shared::Reading");
    assert(a && b && conflict && a->keyed);
    assert(!memcmp(&a->minimal_identifier, &b->minimal_identifier, sizeof(ZidlTsIdentifier)));
    assert(memcmp(&a->minimal_identifier, &conflict->minimal_identifier, sizeof(ZidlTsIdentifier)));
    /* Full sample: key=42, temperature=1. Both byte orders and XCDR versions. */
    uint8_t le[] = {0,1,0,0,42,0,0,0,0,0,128,63};
    uint8_t be[] = {0,0,0,0,0,0,0,42,63,128,0,0};
    uint8_t expected[16] = {0,0,0,42};
    uint8_t hash[16];
    for (unsigned v = 0; v < 2; ++v) {
        le[1] = v ? 7 : 1; be[1] = v ? 6 : 0;
        assert(a->validate(le, sizeof le) == ZIDL_TS_OK);
        assert(a->validate(be, sizeof be) == ZIDL_TS_OK);
        assert(a->key_hash(le, sizeof le, &hash) == ZIDL_TS_OK && !memcmp(hash, expected, 16));
        assert(a->key_hash(be, sizeof be, &hash) == ZIDL_TS_OK && !memcmp(hash, expected, 16));
        assert(a->key_only_hash(le, 8, &hash) == ZIDL_TS_OK && !memcmp(hash, expected, 16));
        assert(a->key_only_hash(be, 8, &hash) == ZIDL_TS_OK && !memcmp(hash, expected, 16));
        assert(a->validate(le, sizeof le - 1) == ZIDL_TS_INVALID_DATA);
        assert(a->key_only_hash(le, sizeof le, &hash) == ZIDL_TS_INVALID_DATA);
    }
    memset(hash, 0x99, sizeof hash);
    assert(a->key_hash(le, 7, &hash) == ZIDL_TS_INVALID_DATA);
    for (unsigned i = 0; i < 16; ++i) assert(hash[i] == 0x99);
    assert(a->validate(NULL, 12) == ZIDL_TS_INVALID_DATA);
    assert(a->key_hash(le, sizeof le, NULL) == ZIDL_TS_INVALID_ARGUMENT);
    le[1] = 9;
    assert(a->validate(le, sizeof le) == ZIDL_TS_UNSUPPORTED);
    const ZidlTsType *counter = find(libs[1], "ProjectB::Counter");
    uint8_t sample[13] = {0,7,0,0}; sample[12] = 1;
    assert(counter && counter->keyed == 0);
    assert(counter->validate(sample, sizeof sample) == ZIDL_TS_OK);
    sample[12] = 2;
    assert(counter->validate(sample, sizeof sample) == ZIDL_TS_INVALID_DATA);
    const ZidlTsType *nonleading = find(libs[0], "ProjectA::NonLeading");
    uint8_t nonleading_data[] = {0,7,0,0,0,0,128,63,42,0,0,0,1,2};
    uint8_t keys[] = {0,7,0,0,42,0,0,0,1,2};
    uint8_t expected_two_keys[16] = {0,0,0,42,2,1};
    assert(nonleading && nonleading->key_hash(nonleading_data, sizeof nonleading_data, &hash) == ZIDL_TS_OK);
    assert(!memcmp(hash, expected_two_keys, 16));
    assert(nonleading->key_only_hash(keys, sizeof keys, &hash) == ZIDL_TS_OK);
    assert(!memcmp(hash, expected_two_keys, 16));
    const ZidlTsType *vector = find(libs[0], "ProjectA::Vector");
    uint8_t vector_data[12] = {0,7,0,0};
    assert(vector && vector->validate(vector_data, sizeof vector_data) == ZIDL_TS_OK);
    assert(vector->validate(vector_data, sizeof vector_data - 1) == ZIDL_TS_INVALID_DATA);
    /* Keep both implementations usable while independently loaded. */
    le[1] = 7;
    assert(b->validate(le, sizeof le) == ZIDL_TS_OK);
    for (unsigned i = 3; i > 0; --i) assert(dlclose(handles[i - 1]) == 0);
    puts("C ABI: independent providers, equivalent/conflicting exports, full/key-only samples and failures passed");
    return 0;
}
