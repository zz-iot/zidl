/* Exposes the provider's counters (provider.zig) to StandaloneTest.java. */
#include <jni.h>
#include <stdint.h>

typedef struct {
    int32_t live;
    int32_t destroys;
    int32_t releases;
} Stats;

Stats test_stats(void);
void test_stats_reset(void);

JNIEXPORT jintArray JNICALL Java_StandaloneTest_nStats(JNIEnv *env, jclass cls) {
    (void)cls;
    Stats s = test_stats();
    jint values[3] = {s.live, s.destroys, s.releases};
    jintArray out = (*env)->NewIntArray(env, 3);
    if (out != NULL) (*env)->SetIntArrayRegion(env, out, 0, 3, values);
    return out;
}

JNIEXPORT void JNICALL Java_StandaloneTest_nReset(JNIEnv *env, jclass cls) {
    (void)env;
    (void)cls;
    test_stats_reset();
}
