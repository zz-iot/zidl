/* Hand-written native backing for test/integration/java/entity.idl.
 *
 * Plays the same role `libzzdds.so` plays for the real DDS bindings: a real
 * C ABI implementation the generated `entity_jni.c` bridge links against,
 * so the Java integration test exercises actual entity boxing/unboxing
 * end-to-end (create → return an entity, take it back as a param, delete),
 * not just compile the bridge in isolation.
 */
#include "entity.h"

#include <jni.h>
#include <stdint.h>
#include <stdlib.h>

typedef struct Widgets_Widget_s {
    int32_t value;
} WidgetObj;

typedef struct Widgets_Factory_s {
    int _unused;
} FactoryObj;

Widgets_Widget Widgets_Factory_create_widget(Widgets_Factory self, int32_t value) {
    (void)self;
    WidgetObj *w = malloc(sizeof(WidgetObj));
    w->value = value;
    return w;
}

int32_t Widgets_Factory_get_widget_value(Widgets_Factory self, Widgets_Widget w) {
    (void)self;
    return w->value;
}

int32_t Widgets_Widget_get_value(Widgets_Widget self) {
    return self->value;
}

/* Parts. Every part lives in one static slot, so a part created after one is
 * deleted has the deleted part's address: what a real allocator may do for
 * entities of different types, made deterministic. */
enum { PART_NONE, PART_GEAR, PART_SPRING };

typedef struct {
    int kind;
    int32_t id;
    int32_t value;
} PartObj;

static PartObj g_part_slot;
static Widgets_PartListener g_listener;

void Widgets_Factory_set_listener(Widgets_Factory self, const Widgets_PartListener *listener) {
    (void)self;
    if (g_listener.release_listener_data)
        g_listener.release_listener_data(g_listener.listener_data);
    g_listener = listener ? *listener : (Widgets_PartListener){0};
}

void Widgets_Factory_fire_part(Widgets_Factory self) {
    (void)self;
    if (g_listener.on_part)
        g_listener.on_part((Widgets_Gear)&g_part_slot, g_listener.listener_data);
}

static int32_t g_next_part_id = 1;
static int g_part_retired;

static void *part_create(int kind, int32_t value) {
    g_part_retired = 0;
    g_part_slot.kind = kind;
    g_part_slot.id = g_next_part_id++;
    g_part_slot.value = value;
    return &g_part_slot;
}

Widgets_Gear Widgets_Factory_create_gear(Widgets_Factory self, int32_t teeth) {
    (void)self;
    return (Widgets_Gear)part_create(PART_GEAR, teeth);
}

Widgets_Spring Widgets_Factory_create_spring(Widgets_Factory self, int32_t rate) {
    (void)self;
    return (Widgets_Spring)part_create(PART_SPRING, rate);
}

/* The handle-retire hook (--handle-retire-hook entity_retire): a provider
 * reports each handle it frees before the address can name anything else. */
static void (*g_retire_fn)(void *ctx, void *handle);
static void *g_retire_ctx;

int entity_is_retired(void *handle) {
    return handle == &g_part_slot && g_part_retired;
}

int entity_retire_observe(void (*fn)(void *ctx, void *handle), void *ctx) {
    if (g_retire_fn != NULL) return 1;
    g_retire_fn = fn;
    g_retire_ctx = ctx;
    return 0;
}

int entity_retire_unobserve(void (*fn)(void *ctx, void *handle), void *ctx) {
    if (g_retire_fn != fn || g_retire_ctx != ctx) return 1;
    g_retire_fn = NULL;
    return 0;
}

void Widgets_Factory_delete_part(Widgets_Factory self, Widgets_Part p) {
    (void)self;
    g_part_retired = 1;
    if (g_retire_fn != NULL) g_retire_fn(g_retire_ctx, p);
    /* Keep the native slot readable until its simulated references drain. */
}

void Widgets_Factory_forget_part(Widgets_Factory self, Widgets_Part p) {
    (void)self;
    ((PartObj *)p)->kind = PART_NONE;
}

/* Counts calls that reach the native side, so the test can tell a retired
 * wrapper did not. */
static int32_t g_turns;

int32_t Widgets_Gear_turn(Widgets_Gear self) {
    (void)self;
    g_turns++;
    return 0;
}

JNIEXPORT jint JNICALL Java_EntityTest_nTurns(JNIEnv *env, jclass cls) {
    (void)env;
    (void)cls;
    return g_turns;
}

Widgets_Part Widgets_Factory_current_part(Widgets_Factory self) {
    (void)self;
    return g_part_slot.kind == PART_NONE ? NULL : (Widgets_Part)&g_part_slot;
}

static int32_t part_id(void *p) { return ((PartObj *)p)->id; }
static int32_t part_value(void *p, int kind) {
    PartObj *o = (PartObj *)p;
    return o->kind == kind ? o->value : -1;
}

int32_t Widgets_Part_get_id(Widgets_Part self) { return part_id(self); }
int32_t Widgets_Gear_get_id(Widgets_Gear self) { return part_id(self); }
int32_t Widgets_Spring_get_id(Widgets_Spring self) { return part_id(self); }
int32_t Widgets_Gear_get_teeth(Widgets_Gear self) { return part_value(self, PART_GEAR); }
int32_t Widgets_Spring_get_rate(Widgets_Spring self) { return part_value(self, PART_SPRING); }

Widgets_Part Widgets_Gear_as_Widgets_Part(Widgets_Gear child) { return (Widgets_Part)child; }
Widgets_Part Widgets_Spring_as_Widgets_Part(Widgets_Spring child) { return (Widgets_Part)child; }
Widgets_Gear Widgets_Part_as_Widgets_Gear(Widgets_Part base) {
    return base != NULL && ((PartObj *)base)->kind == PART_GEAR ? (Widgets_Gear)base : NULL;
}
Widgets_Spring Widgets_Part_as_Widgets_Spring(Widgets_Part base) {
    return base != NULL && ((PartObj *)base)->kind == PART_SPRING ? (Widgets_Spring)base : NULL;
}

/* Synthetic deinit hooks the JNI bridge declares/calls itself (not part of
 * the real generated C ABI above) — see zidl's Java backend `_deinit`. */
void Widgets_Widget_deinit(void *ptr) { free(ptr); }
void Widgets_Factory_deinit(void *ptr) { (void)ptr; }

/* Test-only bootstrap: there is no IDL-level "get the first Factory" op (in
 * real zzdds that's `DomainParticipantFactory`'s well-known singleton
 * accessor) — hand-roll one JNI entry point so Test.java can obtain a valid
 * native handle to start from. */
static FactoryObj g_factory_singleton;

JNIEXPORT jlong JNICALL Java_EntityTest_nGetFactory(JNIEnv *env, jclass cls) {
    (void)env;
    (void)cls;
    return (jlong)(intptr_t)&g_factory_singleton;
}
