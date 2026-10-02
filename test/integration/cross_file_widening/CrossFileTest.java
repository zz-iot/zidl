// Runs the generated Java JNI bindings for core.idl + plugin.idl against
// native.c: plugin::Reader::id_of, declared with an imported
// core::TopicDescription parameter, must accept core::Topic and
// core::ContentFilteredTopic objects and pass their TopicDescription view to
// the C ABI (native.c returns -1 for an unconverted handle).
//
// Compiled and run by `zig build integration-test`.
public class CrossFileTest {
    static { System.loadLibrary("xfw_jni"); }

    static native long nGetFactory();
    static native long nGetReader();

    static void check(boolean cond, String msg) {
        if (!cond) throw new AssertionError("FAIL: " + msg);
    }

    public static void main(String[] args) {
        xfw.core.Core.core.Factory factory = new xfw.core.FactoryImpl(nGetFactory());
        xfw.plugin.Plugin.plugin.Reader reader = new xfw.plugin.ReaderImpl(nGetReader());

        xfw.core.Core.core.Topic topic = factory.create_topic(11);
        xfw.core.Core.core.ContentFilteredTopic cft = factory.create_cft(22);
        check(topic.get_id() == 11, "topic.get_id()");
        check(cft.get_id() == 22, "cft.get_id()");

        check(reader.id_of(topic) == 11, "id_of(core::Topic) passes the TopicDescription view");
        check(reader.id_of(cft) == 22, "id_of(core::ContentFilteredTopic) passes the TopicDescription view");

        System.out.println("cross_file_widening Java: all checks passed");
    }
}
