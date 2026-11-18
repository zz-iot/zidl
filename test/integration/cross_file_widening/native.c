/* Hand-written C ABI for core.idl + plugin.idl (see ../java/entity_native.c for
 * the pattern). Like the real zzdds C ABI, each interface view of an entity
 * is a distinct handle: a Topic's TopicDescription view is the embedded `td`
 * member, reached only through core_Topic_as_core_TopicDescription. Every
 * struct starts with a tag, so plugin_Reader_id_of can tell whether a binding
 * passed the TopicDescription view or an unconverted Topic/CFT handle (-1).
 * A plugin::Topic embeds its core::Topic view the same way, so an inherited
 * core operation called with an unconverted plugin::Topic handle returns -1.
 */
#include "core.h"
#include "plugin.h"

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

enum { TAG_TD = 0x7D7D, TAG_TOPIC = 0x7070, TAG_CFT = 0xCF7C, TAG_PLUGIN_TOPIC = 0x9797 };

struct core_TopicDescription_s {
    int tag;
    int32_t id;
    int owner_tag;
    void *owner;
};
struct core_Topic_s {
    int tag;
    struct core_TopicDescription_s td;
    struct plugin_Topic_s *ext; /* the plugin::Topic this view belongs to, if any */
};
struct core_ContentFilteredTopic_s {
    int tag;
    struct core_TopicDescription_s td;
};
struct core_Factory_s {
    int unused;
};
struct plugin_Topic_s {
    int tag;
    struct core_Topic_s topic;
    int32_t plugin_id;
};
struct plugin_Reader_s {
    int unused;
};

static void init_td(struct core_TopicDescription_s *td, int32_t id, int owner_tag, void *owner) {
    td->tag = TAG_TD;
    td->id = id;
    td->owner_tag = owner_tag;
    td->owner = owner;
}

core_Topic core_Factory_create_topic(core_Factory self, int32_t id) {
    (void)self;
    struct core_Topic_s *t = malloc(sizeof *t);
    t->tag = TAG_TOPIC;
    init_td(&t->td, id, TAG_TOPIC, t);
    t->ext = NULL;
    return t;
}

core_ContentFilteredTopic core_Factory_create_cft(core_Factory self, int32_t id) {
    (void)self;
    struct core_ContentFilteredTopic_s *c = malloc(sizeof *c);
    c->tag = TAG_CFT;
    init_td(&c->td, id, TAG_CFT, c);
    return c;
}

int32_t core_TopicDescription_get_id(core_TopicDescription self) {
    return (self && self->tag == TAG_TD) ? self->id : -1;
}
int32_t core_Topic_get_id(core_Topic self) {
    return (self && self->tag == TAG_TOPIC) ? self->td.id : -1;
}
int32_t core_ContentFilteredTopic_get_id(core_ContentFilteredTopic self) {
    return (self && self->tag == TAG_CFT) ? self->td.id : -1;
}

core_TopicDescription core_Topic_as_core_TopicDescription(core_Topic child) {
    return (child && child->tag == TAG_TOPIC) ? &child->td : NULL;
}
core_TopicDescription core_ContentFilteredTopic_as_core_TopicDescription(core_ContentFilteredTopic child) {
    return (child && child->tag == TAG_CFT) ? &child->td : NULL;
}
core_Topic core_TopicDescription_as_core_Topic(core_TopicDescription base) {
    return (base && base->tag == TAG_TD && base->owner_tag == TAG_TOPIC) ? base->owner : NULL;
}
core_ContentFilteredTopic core_TopicDescription_as_core_ContentFilteredTopic(core_TopicDescription base) {
    return (base && base->tag == TAG_TD && base->owner_tag == TAG_CFT) ? base->owner : NULL;
}

/* The operation under test: only a TopicDescription view is valid here. */
int32_t plugin_Reader_id_of(plugin_Reader self, core_TopicDescription t) {
    (void)self;
    return core_TopicDescription_get_id(t);
}

plugin_Topic plugin_Reader_create_plugin_topic(plugin_Reader self, int32_t id) {
    (void)self;
    struct plugin_Topic_s *p = malloc(sizeof *p);
    p->tag = TAG_PLUGIN_TOPIC;
    p->topic.tag = TAG_TOPIC;
    init_td(&p->topic.td, id, TAG_TOPIC, &p->topic);
    p->topic.ext = p;
    p->plugin_id = id * 10;
    return p;
}

int32_t plugin_Topic_plugin_id(plugin_Topic self) {
    return (self && self->tag == TAG_PLUGIN_TOPIC) ? self->plugin_id : -1;
}
core_Topic plugin_Topic_as_core_Topic(plugin_Topic child) {
    return (child && child->tag == TAG_PLUGIN_TOPIC) ? &child->topic : NULL;
}
plugin_Topic core_Topic_as_plugin_Topic(core_Topic base) {
    return (base && base->tag == TAG_TOPIC) ? base->ext : NULL;
}

static struct core_Factory_s g_factory;
static struct plugin_Reader_s g_reader;

core_Factory xfw_factory(void) { return &g_factory; }
plugin_Reader xfw_reader(void) { return &g_reader; }
