#ifndef ZIDL_TYPESUPPORT_H
#define ZIDL_TYPESUPPORT_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Experimental ABI major: intentionally not a stable published contract. */
#define ZIDL_TS_ABI_MAJOR UINT32_C(0x80000001)
#define ZIDL_TS_OK 0u
#define ZIDL_TS_ABI_MISMATCH 1u
#define ZIDL_TS_INVALID_DATA 2u
#define ZIDL_TS_UNSUPPORTED 3u
#define ZIDL_TS_INVALID_ARGUMENT 4u
#define ZIDL_TS_XCDR1 1u
#define ZIDL_TS_XCDR2 2u
/* Every pointer is borrowed and requires the supplying library to remain loaded.
 * Spans have exact lengths, not NUL-terminated strings. Callbacks are synchronous,
 * reentrant, allocation-free and retain no inputs. Output is untouched on failure.
 * Input is DDS-encapsulated CDR. Empty/null input is invalid. */
typedef struct { const uint8_t *data; uint64_t size; } ZidlTsBytes;
typedef struct { uint8_t value[15]; } ZidlTsIdentifier; /* EK_MINIMAL + hash[14] */
typedef struct {
    uint32_t descriptor_size;
    ZidlTsIdentifier identifier;
    ZidlTsBytes cdr; /* Encapsulated XCDR2_LE TypeObject; hash excludes encapsulation. */
    const ZidlTsIdentifier *dependencies; /* Direct named dependencies. */
    uint64_t dependency_count;
} ZidlTsObject;
typedef uint32_t (*ZidlTsValidate)(const uint8_t *, uint64_t);
typedef uint32_t (*ZidlTsKeyHash)(const uint8_t *, uint64_t, uint8_t (*)[16]);
typedef struct {
    uint32_t descriptor_size;
    uint32_t representations; /* bitmask, XCDR1/XCDR2, both byte orders */
    ZidlTsBytes name;
    ZidlTsIdentifier minimal_identifier;
    uint8_t keyed; /* exactly 0 or 1 */
    ZidlTsValidate validate;
    ZidlTsKeyHash key_hash;
    ZidlTsKeyHash key_only_hash;
} ZidlTsType;
typedef struct {
    uint32_t descriptor_size;
    uint32_t abi_major;
    uint32_t abi_minor;
    uint32_t required_features; /* zero for this prototype */
    const ZidlTsType *types;
    uint64_t type_count;
    const ZidlTsObject *objects; /* Self-contained named metadata catalog. */
    uint64_t object_count;
} ZidlTsLibrary;
/* On any failure, *out is NULL. Static consumers use the same descriptor. */
typedef uint32_t (*ZidlTsQuery)(uint32_t requested_major, const ZidlTsLibrary **out);
uint32_t zidl_typesupport_query(uint32_t requested_major, const ZidlTsLibrary **out);
#ifdef __cplusplus
}
#endif
#endif
