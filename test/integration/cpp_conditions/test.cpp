// Compile and run the generated condition bridge against a synthetic C ABI.
#include "dcps_impl.hpp"
#include <cassert>
#include <type_traits>

static_assert(std::is_convertible_v<std::shared_ptr<DDS::QueryCondition>, std::shared_ptr<DDS::ReadCondition>>);
static_assert(!std::is_convertible_v<std::shared_ptr<DDS::GuardCondition>, std::shared_ptr<DDS::ReadCondition>>);
static_assert(!std::is_convertible_v<std::shared_ptr<DDS::StatusCondition>, std::shared_ptr<DDS::ReadCondition>>);

struct DDS_Condition_s {};
struct DDS_ReadCondition_s { DDS_Condition root; };
struct DDS_QueryCondition_s { DDS_ReadCondition base; };
struct DDS_GuardCondition_s { DDS_Condition root; };
struct DDS_StatusCondition_s { DDS_Condition root; };
struct DDS_DataReader_s {};

static DDS_ReadCondition expected_condition;
static int calls;
static DDS_OctetSeqSeq *expected_payloads;
static DDS_OctetSeq *expected_hashes;
static DDS_SampleInfoSeq *expected_infos;

extern "C" {
DDS_Condition DDS_ReadCondition_as_DDS_Condition(DDS_ReadCondition h) { return h ? h->root : nullptr; }
DDS_ReadCondition DDS_QueryCondition_as_DDS_ReadCondition(DDS_QueryCondition h) { return h ? h->base : nullptr; }
DDS_Condition DDS_GuardCondition_as_DDS_Condition(DDS_GuardCondition h) { return h ? h->root : nullptr; }
DDS_Condition DDS_StatusCondition_as_DDS_Condition(DDS_StatusCondition h) { return h ? h->root : nullptr; }
DDS_DataReader DDS_DataReader_get_reader(DDS_DataReader h) { return h; }
DDS_Condition DDS_DataReader_get_condition(DDS_DataReader) { return nullptr; }
DDS_ReadCondition DDS_DataReader_get_readcondition(DDS_DataReader) { return nullptr; }
DDS_QueryCondition DDS_DataReader_get_querycondition(DDS_DataReader) { return nullptr; }
DDS_GuardCondition DDS_DataReader_get_guardcondition(DDS_DataReader) { return nullptr; }
DDS_StatusCondition DDS_DataReader_get_statuscondition(DDS_DataReader) { return nullptr; }

#define RAW_OP(name, result) \
int32_t DDS_DataReader_##name(DDS_DataReader reader, DDS_OctetSeqSeq *payloads, DDS_OctetSeq *hashes, DDS_SampleInfoSeq *infos, int32_t handle, DDS_ReadCondition condition, uint32_t ss, uint32_t vs, uint32_t is, int32_t max) { \
    assert(reader && condition == expected_condition); \
    assert(payloads == expected_payloads && hashes == expected_hashes && infos == expected_infos); \
    assert(handle == 42 && ss == 1 && vs == 2 && is == 4 && max == 8); \
    ++calls; return result; \
}
RAW_OP(take_raw, 11)
RAW_OP(read_raw, 12)
RAW_OP(take_next_instance_raw, 13)
RAW_OP(read_next_instance_raw, 14)
#undef RAW_OP
}

int main() {
    DDS_DataReader_s reader_handle;
    auto reader = DDS::DataReaderImpl::_getOrCreate(&reader_handle);
    assert(reader == reader->get_reader());
    DDS_Condition_s roots[4];
    DDS_ReadCondition_s read_handle{&roots[0]}, query_read_handle{&roots[1]};
    // Distinct pointers ensure adaptation must call the ABI upcast helper.
    DDS_QueryCondition_s query_handle{&query_read_handle};
    DDS_GuardCondition_s guard_handle{&roots[2]};
    DDS_StatusCondition_s status_handle{&roots[3]};
    auto read = DDS::ReadConditionImpl::_getOrCreate(&read_handle);
    auto query = DDS::QueryConditionImpl::_getOrCreate(&query_handle);
    auto guard = DDS::GuardConditionImpl::_getOrCreate(&guard_handle);
    auto status = DDS::StatusConditionImpl::_getOrCreate(&status_handle);

    DDS_OctetSeqSeq payloads{};
    DDS_OctetSeq hashes{};
    DDS_SampleInfoSeq infos{};
    expected_payloads = &payloads;
    expected_hashes = &hashes;
    expected_infos = &infos;
    auto exercise = [&](std::shared_ptr<DDS::ReadCondition> condition, DDS_ReadCondition handle) {
        expected_condition = handle;
        assert(reader->take_raw(payloads, hashes, infos, 42, condition, 1, 2, 4, 8) == 11);
        assert(reader->read_raw(payloads, hashes, infos, 42, condition, 1, 2, 4, 8) == 12);
        assert(reader->take_next_instance_raw(payloads, hashes, infos, 42, condition, 1, 2, 4, 8) == 13);
        assert(reader->read_next_instance_raw(payloads, hashes, infos, 42, condition, 1, 2, 4, 8) == 14);
    };
    exercise(read, &read_handle);
    exercise(query, &query_read_handle); // implicit shared_ptr upcast
    exercise(nullptr, nullptr);
    assert(calls == 12);

    // Passing a condition must not replace the shared family-cache entry.
    auto check_identity = [](auto object, DDS_Condition handle) {
        auto roundtrip = DDS::ConditionImpl::_getOrCreate(handle);
        assert(roundtrip == object);
        assert(!roundtrip.owner_before(object) && !object.owner_before(roundtrip));
    };
    check_identity(read, &roots[0]);
    check_identity(query, &roots[1]);
    check_identity(guard, &roots[2]);
    check_identity(status, &roots[3]);

    // A user implementation has no native ABI handle: reject it explicitly.
    auto foreign = std::make_shared<DDS::ReadCondition>();
    bool rejected = false;
    try { exercise(foreign, nullptr); }
    catch (const std::invalid_argument&) { rejected = true; }
    assert(rejected && calls == 12);
}
