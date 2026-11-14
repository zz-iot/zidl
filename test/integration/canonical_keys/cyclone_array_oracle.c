/* Optional independent implementation check; not linked into ordinary tests.
 * Build/run with check_cyclone_arrays.py --cyclone /path/to/cyclonedds. */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include "dds/dds.h"
#include "dds/cdr/dds_cdrstream.h"
#include "array_keys.h"
#define TYPE(name) Canonical_##name
#define INIT {0}
static const dds_cdrstream_allocator_t allocator = { malloc, realloc, free };
static void oracle(const char *name, const void *value, const dds_topic_descriptor_t *topic) {
    struct dds_cdrstream_desc desc;
    dds_cdrstream_desc_from_topic_desc(&desc, topic);
    dds_ostreamBE_t stream;
    dds_ostreamBE_init(&stream, &allocator, 0, DDSI_RTPS_CDR_ENC_VERSION_2);
    // Every field in these FINAL fixtures is a key, so the native sample is
    // also a key-only sample. Extract through the exported KEYHASH-mode API;
    // write_keyBE itself is private in some Cyclone shared-library builds.
    dds_ostream_t sample;
    dds_ostream_init(&sample, &allocator, 0, DDSI_RTPS_CDR_ENC_VERSION_2);
    assert(dds_stream_write_sample(&sample, &allocator, value, &desc));
    dds_istream_t input;
    dds_istream_init(&input, sample.m_index, sample.m_buffer, DDSI_RTPS_CDR_ENC_VERSION_2);
    dds_stream_extract_keyBE_from_key(&input, &stream, DDS_CDR_KEY_SERIALIZATION_KEYHASH,
                                    &allocator, &desc);
    dds_ostream_fini(&sample, &allocator);
    printf("%s ", name);
    for (uint32_t i = 0; i < stream.x.m_index; i++) printf("%02x", stream.x.m_buffer[i]);
    printf(" %d\n", !(desc.flagset & DDS_TOPIC_FIXED_KEY_XCDR2_KEYHASH));
    dds_ostreamBE_fini(&stream, &allocator);
    dds_cdrstream_desc_fini(&desc, &allocator);
}
#define CHECK(NAME, VALUE, CASE, EXT, XCDR1_OK) oracle(CASE, &(VALUE), &Canonical_##NAME##_desc)
#include "array_values.h"
int main(void) { array_key_values(); }
