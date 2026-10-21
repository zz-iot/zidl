const ts = @import("zidl_typesupport");
test "same descriptors work without a dynamic loader" {
    try ts.checkLibrary(&@import("provider").library);
}
