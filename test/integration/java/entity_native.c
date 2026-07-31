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
