/* Identical native values for C, C++, and the optional Cyclone oracle. */
static void array_key_values(void) {
    TYPE(EnumArray16) e16 = INIT;
    e16.values[1] = (TYPE(ArrayEnum))1;
    CHECK(EnumArray16, e16, "EnumArray16", 0, 1);
    TYPE(EnumArray20) e20 = INIT;
    e20.values[1] = e20.values[3] = (TYPE(ArrayEnum))1;
    CHECK(EnumArray20, e20, "EnumArray20", 0, 1);
    TYPE(EnumGrid) grid = INIT;
    grid.values[0][1] = grid.values[1][0] = (TYPE(ArrayEnum))1;
    CHECK(EnumGrid, grid, "EnumGrid", 0, 1);
    TYPE(MaskArray16) m16 = INIT;
    TYPE(MaskArray17) m17 = INIT;
    for (size_t i = 0; i < 12; i++) m16.values[i] = m17.values[i] = (i % 2) ? 2 : 1;
    m17.values[12] = 1;
    CHECK(MaskArray16, m16, "MaskArray16", 0, 1);
    CHECK(MaskArray17, m17, "MaskArray17", 0, 1);
    TYPE(NarrowArray) narrow = INIT;
    narrow.lead = 0xaa; narrow.tail = 0xbb;
    narrow.values[1] = (TYPE(ArrayEnum8))1;
    CHECK(NarrowArray, narrow, "NarrowArray", 0, 1);
    TYPE(Enum16Array) medium = INIT;
    medium.values[1] = (TYPE(ArrayEnum16))1;
    CHECK(Enum16Array, medium, "Enum16Array", 0, 1);
    TYPE(Mask64Array) wide = INIT;
    wide.values[0] = 1; wide.values[1] = 2;
    CHECK(Mask64Array, wide, "Mask64Array", 0, 1);
    TYPE(PrimitiveGrid) primitive = INIT;
    primitive.values[0][0] = 1; primitive.values[0][1] = 2;
    primitive.values[1][0] = 3; primitive.values[1][1] = 4;
    CHECK(PrimitiveGrid, primitive, "PrimitiveGrid", 0, 1);
}
