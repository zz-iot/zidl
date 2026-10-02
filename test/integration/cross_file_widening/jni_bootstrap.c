/* Test-only JNI entry points handing CrossFileTest.java its starting native
 * handles (there is no IDL-level accessor; see ../java/entity_native.c). */
#include "core.h"
#include "plugin.h"

#include <jni.h>
#include <stdint.h>

core_Factory xfw_factory(void);
plugin_Reader xfw_reader(void);

JNIEXPORT jlong JNICALL Java_CrossFileTest_nGetFactory(JNIEnv *env, jclass cls) {
    (void)env;
    (void)cls;
    return (jlong)(intptr_t)xfw_factory();
}

JNIEXPORT jlong JNICALL Java_CrossFileTest_nGetReader(JNIEnv *env, jclass cls) {
    (void)env;
    (void)cls;
    return (jlong)(intptr_t)xfw_reader();
}
