// Drives standalone.idl's generated Java binding against the Zig provider:
// static factories, close() through try-with-resources, the strict
// destructor, the finalizer, and family identity.
//
// Compiled and run by `zig build integration-test`.

public class StandaloneTest {
    static { System.loadLibrary("standalone_jni"); }

    static native int[] nStats();
    static native void nReset();
    static native boolean nLoaded();

    static final int OK = Standalone.S.RETCODE_OK.value;
    static final int PRECONDITION_NOT_MET = Standalone.S.RETCODE_PRECONDITION_NOT_MET.value;
    static final int ALREADY_DELETED = Standalone.S.RETCODE_ALREADY_DELETED.value;

    static void check(boolean cond, String msg) {
        if (!cond) throw new AssertionError("FAIL: " + msg);
    }

    static void stats(int live, int destroys, int releases, String msg) {
        int[] s = nStats();
        check(s[0] == live && s[1] == destroys && s[2] == releases,
              msg + ": live " + s[0] + " destroys " + s[1] + " releases " + s[2]);
    }

    static Standalone.S.Config config(int workers) {
        Standalone.S.Config cfg = new Standalone.S.Config();
        cfg.set_workers(workers);
        return cfg;
    }

    public static void main(String[] args) {
        check(nLoaded(), "JNI_OnLoad ran the --java-jni-onload-hook");

        nReset();
        try (Standalone.S.Engine e = Standalone.S.Engine.create()) {
            check(e != null, "create() returns an engine");
            check(e.get_workers() == 1, "the default engine has one worker");
            stats(1, 0, 0, "one engine is live");
        }
        stats(0, 0, 1, "close() runs the finalizer");

        nReset();
        Standalone.S.Engine pinned = Standalone.S.Engine.create_with(config(3), 1);
        check(pinned.get_workers() == 3, "constructor arguments reach the provider");
        check(pinned.destroy() == PRECONDITION_NOT_MET, "destroy() refuses a pinned engine");
        stats(1, 0, 0, "a refused destroy leaves the engine");
        check(pinned.unpin() == OK, "unpin");
        check(pinned.destroy() == OK, "destroy() succeeds once unpinned");
        stats(0, 1, 0, "destroy() released the engine");
        check(pinned.destroy() == ALREADY_DELETED, "a second destroy() does not reach the provider");
        check(pinned.get_workers() == 0, "a destroyed engine's other operations do not reach the provider");
        check(pinned.unpin() == ALREADY_DELETED, "unpin() after destroy() does not reach the provider");
        pinned.close();
        stats(0, 1, 0, "close() after destroy() releases nothing");

        nReset();
        Standalone.S.Engine released = Standalone.S.Engine.create_with(config(2), 4);
        released.release();
        released.release();
        check(released.get_workers() == 0, "a released engine's other operations do not reach the provider");
        check(released.destroy() == ALREADY_DELETED, "destroy() after release() does not reach the provider");
        released.close();
        stats(0, 0, 1, "close() after release() releases nothing more");

        // A released engine's address comes back for the next one. Every old
        // wrapper stays reachable, so a cache that kept released handles
        // would hand one of them back.
        nReset();
        java.util.List<Standalone.S.Engine> kept = new java.util.ArrayList<>();
        for (int i = 0; i < 16; i++) {
            Standalone.S.Engine e = Standalone.S.Engine.create();
            check(e != null && !kept.contains(e), "each create() returns a new wrapper");
            check(e.get_workers() == 1, "a new engine at a reused address works");
            if (i % 2 == 0) e.close(); else check(e.destroy() == OK, "destroy");
            kept.add(e);
        }
        stats(0, 8, 8, "each engine was released once");

        nReset();
        check(Standalone.S.Engine.create_with(config(0), 0) == null, "a failed constructor returns null");
        stats(0, 0, 0, "a failed constructor leaves nothing");

        nReset();
        try (Standalone.S.Guard g = Standalone.S.Guard.create();
             Standalone.S.Holder h = Standalone.S.Holder.create()) {
            check(h.hold(g) == OK, "hold");
            check(h.held() == g, "the family cache hands back the creator's wrapper");
            check(g.set_trigger_value(true) == OK, "set_trigger_value");
            check(h.held().get_trigger_value(), "the trigger set through the guard is seen through its condition");
        }
        stats(0, 2, 0, "close() without a finalizer runs the destructor");

        System.out.println("standalone construction: Java checks passed");
    }
}
