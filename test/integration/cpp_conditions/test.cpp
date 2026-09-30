// Compile and run the generated condition bridge against a synthetic C ABI.
#include "topic.hpp"
#include "dcps_impl.hpp"
#include <cassert>
#include <type_traits>

static_assert(std::is_convertible_v<std::shared_ptr<DDS::QueryCondition>, std::shared_ptr<DDS::ReadCondition>>);
static_assert(!std::is_convertible_v<std::shared_ptr<DDS::GuardCondition>, std::shared_ptr<DDS::ReadCondition>>);
static_assert(!std::is_convertible_v<std::shared_ptr<DDS::StatusCondition>, std::shared_ptr<DDS::ReadCondition>>);

// Check the public typed signatures, including rejection of raw handles and
// sibling conditions. QueryCondition conversion must work for every method.
#define CHECK_CONDITION_METHOD(name, ...) \
static_assert(std::is_invocable_v<decltype(&TopicDataReader::name), TopicDataReader&, std::shared_ptr<DDS::QueryCondition>, __VA_ARGS__>); \
static_assert(!std::is_invocable_v<decltype(&TopicDataReader::name), TopicDataReader&, std::shared_ptr<DDS::GuardCondition>, __VA_ARGS__>); \
static_assert(!std::is_invocable_v<decltype(&TopicDataReader::name), TopicDataReader&, std::shared_ptr<DDS::StatusCondition>, __VA_ARGS__>); \
static_assert(!std::is_invocable_v<decltype(&TopicDataReader::name), TopicDataReader&, DDS_ReadCondition, __VA_ARGS__>);
CHECK_CONDITION_METHOD(take_w_condition, Topic*, DDS_SampleInfo*, int)
CHECK_CONDITION_METHOD(read_w_condition, Topic*, DDS_SampleInfo*, int)
CHECK_CONDITION_METHOD(take_next_instance_w_condition, DDS_InstanceHandle_t, Topic*, DDS_SampleInfo*, int)
CHECK_CONDITION_METHOD(read_next_instance_w_condition, DDS_InstanceHandle_t, Topic*, DDS_SampleInfo*, int)
#undef CHECK_CONDITION_METHOD

struct DDS_Condition_s {};
struct DDS_ReadCondition_s { DDS_Condition root; };
struct DDS_QueryCondition_s { DDS_ReadCondition base; };
struct DDS_GuardCondition_s { DDS_Condition root; };
struct DDS_StatusCondition_s { DDS_Condition root; };
struct DDS_DataReader_s {};

static DDS_ReadCondition expected_condition;
static int calls;
static bool typed_mode;
static int expected_op;
static int32_t expected_handle;
static DDS_ReturnCode_t typed_result = DDS_RETCODE_OK;
static int loans;
// XCDR1 little-endian encapsulation followed by Topic.id = 123.
static uint8_t sample_bytes[] = {0, 1, 0, 0, 123, 0, 0, 0};
static DDS_OctetSeq sample_payload{8, 8, sample_bytes, false};
static DDS_SampleInfo sample_info{true};
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
    if (typed_mode) { \
        assert(expected_op == result && handle == expected_handle); \
        assert(ss == DDS_ANY_SAMPLE_STATE && vs == DDS_ANY_VIEW_STATE && is == DDS_ANY_INSTANCE_STATE && max == 8); \
        assert(payloads->_maximum == 1 && payloads->_length == 0); \
        if (typed_result == DDS_RETCODE_OK) { \
            payloads->_length = 1; payloads->_buffer = &sample_payload; \
            infos->_length = 1; infos->_buffer = &sample_info; \
        } \
        ++calls; return typed_result; \
    } \
    assert(payloads == expected_payloads && hashes == expected_hashes && infos == expected_infos); \
    assert(handle == 42 && ss == 1 && vs == 2 && is == 4 && max == 8); \
    ++calls; return result; \
}
RAW_OP(take_raw, 11)
RAW_OP(read_raw, 12)
RAW_OP(take_next_instance_raw, 13)
RAW_OP(read_next_instance_raw, 14)
#undef RAW_OP
DDS_ReturnCode_t DDS_DataReader_return_loan_raw(DDS_DataReader reader, DDS_OctetSeqSeq*, DDS_OctetSeq*, DDS_SampleInfoSeq*) {
    assert(reader && typed_mode);
    ++loans;
    return DDS_RETCODE_OK;
}
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

    // Exercise freshly generated typed methods, not just the raw bridge.
    typed_mode = true;
    TopicDataReader typed(&reader_handle);
    Topic values[8];
    DDS_SampleInfo sample_infos[8];
    auto exercise_typed = [&](auto condition, DDS_ReadCondition handle) {
        expected_condition = handle;
        const int expected_result = typed_result == DDS_RETCODE_OK ? 1 : -1;
        expected_handle = DDS_HANDLE_NIL;
        expected_op = 11;
        assert(typed.take_w_condition(condition, values, sample_infos, 8) == expected_result);
        expected_op = 12;
        assert(typed.read_w_condition(condition, values, sample_infos, 8) == expected_result);
        expected_handle = 42;
        expected_op = 13;
        assert(typed.take_next_instance_w_condition(condition, 42, values, sample_infos, 8) == expected_result);
        expected_op = 14;
        assert(typed.read_next_instance_w_condition(condition, 42, values, sample_infos, 8) == expected_result);
        if (typed_result == DDS_RETCODE_OK) assert(values[0].id == 123 && sample_infos[0].valid_data);
    };
    exercise_typed(read, &read_handle);
    exercise_typed(query, &query_read_handle); // upcast at the typed entry points
    exercise_typed(nullptr, nullptr);
    assert(calls == 24 && loans == 12);
    typed_result = DDS_RETCODE_BAD_PARAMETER;
    exercise_typed(query, &query_read_handle);
    assert(calls == 28 && loans == 12); // no return-loan call after an ABI error
    TopicDataReader nil(nullptr);
    assert(nil.take_w_condition(query, values, sample_infos, 8) == -1);
    assert(nil.read_w_condition(query, values, sample_infos, 8) == -1);
    assert(nil.take_next_instance_w_condition(query, 42, values, sample_infos, 8) == -1);
    assert(nil.read_next_instance_w_condition(query, 42, values, sample_infos, 8) == -1);
    assert(calls == 28);
    assert(DDS::DataReaderImpl::_getOrCreate(&reader_handle) == reader);

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
    try { exercise_typed(foreign, nullptr); }
    catch (const std::invalid_argument&) { rejected = true; }
    assert(rejected && calls == 28);
}
