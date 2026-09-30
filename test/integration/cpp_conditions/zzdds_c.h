#pragma once
// Synthetic middleware contract for compiling the complete generated topic
// wrapper. Only reader operations are exercised; unrelated calls fail loudly.
#include "dcps.h"
#include <cstdlib>
#include <cstddef>

typedef int32_t DDS_ReturnCode_t;
typedef int32_t DDS_InstanceHandle_t;
typedef void *DDS_DataWriter;
typedef void *DDS_DomainParticipant;
struct DDS_Time_t { int32_t sec; uint32_t nanosec; };
enum DDS_WriteKind { DDS_WriteKind_ALIVE_WRITE_KIND, DDS_WriteKind_DISPOSE_WRITE_KIND, DDS_WriteKind_UNREGISTER_WRITE_KIND };
constexpr int DDS_RETCODE_OK = 0;
constexpr int DDS_RETCODE_BAD_PARAMETER = 3;
constexpr int DDS_RETCODE_NO_DATA = 11;
constexpr DDS_InstanceHandle_t DDS_HANDLE_NIL = 0;
constexpr uint32_t DDS_ANY_SAMPLE_STATE = 3;
constexpr uint32_t DDS_ANY_VIEW_STATE = 3;
constexpr uint32_t DDS_ANY_INSTANCE_STATE = 7;
struct zzdds_filter_value {
    int kind;
    int64_t i;
    double f;
    const uint8_t *s_ptr;
    size_t s_len;
};
extern "C" DDS_ReturnCode_t DDS_DataReader_return_loan_raw(
    DDS_DataReader, DDS_OctetSeqSeq *, DDS_OctetSeq *, DDS_SampleInfoSeq *);

// Templates accept the generated support signatures without pretending to
// implement writer/type-registration behavior in this reader-only fixture.
#define UNUSED_SUPPORT(name) template<class... Args> inline int name(Args...) { std::abort(); }
UNUSED_SUPPORT(DDS_DataWriter_write_raw)
UNUSED_SUPPORT(DDS_DataWriter_loan_raw)
UNUSED_SUPPORT(DDS_DataWriter_return_loan_raw)
UNUSED_SUPPORT(DDS_DataWriter_publish_loan_raw)
UNUSED_SUPPORT(zzdds_register_type_support)
UNUSED_SUPPORT(zzdds_register_instance_raw)
UNUSED_SUPPORT(zzdds_get_key_value_writer)
UNUSED_SUPPORT(zzdds_get_key_value_reader)
UNUSED_SUPPORT(zzdds_lookup_instance_writer)
UNUSED_SUPPORT(zzdds_lookup_instance_reader)
#undef UNUSED_SUPPORT
