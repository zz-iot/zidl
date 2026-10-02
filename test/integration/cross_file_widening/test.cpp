// Compiles and runs the generated C++ bindings for core.idl + plugin.idl against
// native.c: plugin::Reader::id_of, declared with an imported
// core::TopicDescription parameter, must accept the imported subtypes
// core::Topic and core::ContentFilteredTopic and pass their TopicDescription
// view to the C ABI (native.c returns -1 for any other handle).
#include "core_impl.hpp"
#include "plugin_impl.hpp"

#include <cstdio>
#include <cstdlib>
#include <memory>

extern "C" core_Factory xfw_factory(void);
extern "C" plugin_Reader xfw_reader(void);

#define CHECK(cond)                                                                   \
    do {                                                                              \
        if (!(cond)) {                                                                \
            std::fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #cond); \
            std::exit(1);                                                             \
        }                                                                             \
    } while (0)

int main() {
    auto factory = std::make_shared<::core::FactoryImpl>(xfw_factory());
    auto reader = std::make_shared<::plugin::ReaderImpl>(xfw_reader());

    std::shared_ptr<::core::Topic> topic = factory->create_topic(11);
    std::shared_ptr<::core::ContentFilteredTopic> cft = factory->create_cft(22);
    CHECK(topic && cft);
    CHECK(topic->get_id() == 11);
    CHECK(cft->get_id() == 22);

    CHECK(reader->id_of(topic) == 11);
    CHECK(reader->id_of(cft) == 22);

    std::printf("cross_file_widening C++: all checks passed\n");
    return 0;
}
