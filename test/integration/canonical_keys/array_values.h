/* Identical native values for C, C++, and the optional Cyclone oracle. */
static void fixed_array_key_values(void) {
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

#ifdef __cplusplus
#define SET_SEQ(value, data, count) (value).values.assign((data), (data) + (count))
#define CLEAR_SEQ(value) (value).values.clear()
#else
#define SET_SEQ(value, data, count) do { \
    (value).values._buffer = (data); \
    (value).values._length = (value).values._maximum = (count); \
} while (0)
#define CLEAR_SEQ(value) ((value).values._length = 0)
#endif
static void sequence_key_values(void) {
    TYPE(ArrayEnum) enums[] = {(TYPE(ArrayEnum))0, (TYPE(ArrayEnum))1, (TYPE(ArrayEnum))0};
    TYPE(EnumSeq16) e16 = INIT;
    SET_SEQ(e16, enums, 2);
    CHECK(EnumSeq16, e16, "EnumSeq16", 0, 1);
    CLEAR_SEQ(e16);
    CHECK(EnumSeq16, e16, "EnumSeq16Empty", 0, 1);
    TYPE(EnumSeq20) e20 = INIT;
    SET_SEQ(e20, enums, 3);
    CHECK(EnumSeq20, e20, "EnumSeq20", 0, 1);
    CLEAR_SEQ(e20);
    CHECK(EnumSeq20, e20, "EnumSeq20Empty", 0, 1);
    SET_SEQ(e20, enums + 1, 1);
    CHECK(EnumSeq20, e20, "EnumSeq20Short", 0, 1);
    TYPE(ArrayMask8) masks[] = {1,2,1,2,1,2,1,2,1};
    TYPE(MaskSeq16) m16 = INIT;
    SET_SEQ(m16, masks, 8);
    CHECK(MaskSeq16, m16, "MaskSeq16", 0, 1);
    TYPE(MaskSeq17) m17 = INIT;
    SET_SEQ(m17, masks, 9);
    CHECK(MaskSeq17, m17, "MaskSeq17", 0, 1);
    CLEAR_SEQ(m17);
    CHECK(MaskSeq17, m17, "MaskSeq17Empty", 0, 1);
    TYPE(ArrayEnum8) narrow[] = {(TYPE(ArrayEnum8))0, (TYPE(ArrayEnum8))1, (TYPE(ArrayEnum8))0};
    TYPE(Enum8Seq17) n = INIT;
    SET_SEQ(n, narrow, 3);
    CHECK(Enum8Seq17, n, "Enum8Seq17", 0, 1);
    TYPE(ArrayEnum16) medium[] = {(TYPE(ArrayEnum16))0, (TYPE(ArrayEnum16))1};
    TYPE(Enum16Seq16) med = INIT;
    SET_SEQ(med, medium, 2);
    CHECK(Enum16Seq16, med, "Enum16Seq16", 0, 1);
    TYPE(ArrayMask64) wide[] = {2};
    TYPE(Mask64Seq16) w = INIT;
    SET_SEQ(w, wide, 1);
    CHECK(Mask64Seq16, w, "Mask64Seq16", 0, 1);
    TYPE(EnumUnboundedSeq) unbounded = INIT;
    CHECK(EnumUnboundedSeq, unbounded, "EnumUnboundedSeq", 0, 1);
    TYPE(ArrayPrimitiveAlias) primitives[] = {1,2,3};
    TYPE(PrimitiveSeq16) p = INIT;
    SET_SEQ(p, primitives, 3);
    CHECK(PrimitiveSeq16, p, "PrimitiveSeq16", 0, 1);
    CLEAR_SEQ(p);
    CHECK(PrimitiveSeq16, p, "PrimitiveSeq16Empty", 0, 1);
    TYPE(EnumSeqAlign) aligned = INIT;
    aligned.lead = 0xaa; aligned.tail = 0xbb;
    SET_SEQ(aligned, narrow, 2);
    CHECK(EnumSeqAlign, aligned, "EnumSeqAlign", 0, 1);
}
static void variable_key_values(void) {
    TYPE(TextArray) text_array = INIT;
    TYPE(TextGrid) grid = INIT;
    TYPE(TextSeq) text_seq = INIT;
#ifdef __cplusplus
    text_array.values[0] = "A"; text_array.values[1] = "BC";
    grid.values[0][0] = "A"; grid.values[0][1] = "BC";
    grid.values[1][0] = ""; grid.values[1][1] = "D";
    text_seq.values = {"A", "BC"};
#else
    strcpy(text_array.values[0], "A"); strcpy(text_array.values[1], "BC");
    strcpy(grid.values[0][0], "A"); strcpy(grid.values[0][1], "BC");
    strcpy(grid.values[1][1], "D");
    char words[2][5] = {"A", "BC"};
    SET_SEQ(text_seq, words, 2);
#endif
    CHECK(TextArray, text_array, "TextArray", 0, 1);
    CHECK(TextGrid, grid, "TextGrid", 0, 1);
    CHECK(TextSeq, text_seq, "TextSeq", 0, 1);
    CLEAR_SEQ(text_seq);
    CHECK(TextSeq, text_seq, "TextSeqEmpty", 0, 1);
#ifdef __cplusplus
    text_seq.values = {"A"};
#else
    SET_SEQ(text_seq, words, 1);
#endif
    CHECK(TextSeq, text_seq, "TextSeqShort", 0, 1);
    TYPE(PlainItem) items[2] = INIT;
    items[0].id = 1; items[1].id = 2;
    TYPE(ItemSeq) item_seq = INIT;
    SET_SEQ(item_seq, items, 2);
    TYPE(ItemArray) item_array = INIT;
    item_array.values[0] = items[0]; item_array.values[1] = items[1];
    CHECK(ItemSeq, item_seq, "ItemSeq", 0, 1);
    CHECK(ItemArray, item_array, "ItemArray", 0, 1);
    TYPE(NestedSeq) nested = INIT;
    TYPE(ArraySeq) array_seq = INIT;
#ifdef __cplusplus
    nested.values = {{1, 2}, {}};
    array_seq.values.push_back({(TYPE(ArrayEnum))0, (TYPE(ArrayEnum))1});
#else
    int32_t numbers[2] = {1, 2};
    TYPE(PrimitiveInner) rows[2] = INIT;
    rows[0]._length = rows[0]._maximum = 2; rows[0]._buffer = numbers;
    SET_SEQ(nested, rows, 2);
    TYPE(ArrayEnumRow) enum_rows[1] = {{(TYPE(ArrayEnum))0, (TYPE(ArrayEnum))1}};
    SET_SEQ(array_seq, enum_rows, 1);
#endif
    CHECK(NestedSeq, nested, "NestedSeq", 0, 1);
    CHECK(ArraySeq, array_seq, "ArraySeq", 0, 1);
#ifndef ZIDL_CYCLONE_ORACLE
    TYPE(VariableChoice) choices[2] = INIT;
#ifdef __cplusplus
    choices[0].text("A"); choices[1]._d(1); choices[1].id(7);
#else
    choices[0]._d = 0; strcpy(choices[0]._u.text, "A");
    choices[1]._d = 1; choices[1]._u.id = 7;
#endif
    TYPE(UnionSeq) union_seq = INIT;
    SET_SEQ(union_seq, choices, 2);
    CHECK(UnionSeq, union_seq, "UnionSeq", 0, 1);
#endif
    TYPE(StringEnvelope) envelope = INIT;
    envelope.lead = 0xaa; envelope.tail = 0xbb;
    envelope.inner = text_seq;
    CHECK(StringEnvelope, envelope, "StringEnvelope", 0, 1);
    TYPE(WideArray) wide = INIT;
#ifdef __cplusplus
    wide.values[0] = L"A";
#else
    wide.values[0][0] = 'A';
#endif
    CHECK(WideArray, wide, "WideArray", 0, 1);
}
static void array_key_values(void) {
    fixed_array_key_values();
    sequence_key_values();
    variable_key_values();
}
