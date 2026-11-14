use cdr_abi_experiment::{ByteOrder::*, Counter, Error, Reader, Version::*, Writer};

fn hex(s: &str) -> Vec<u8> {
    let text: String = s.split_whitespace().collect();
    (0..text.len()).step_by(2).map(|i| u8::from_str_radix(&text[i..i+2], 16).unwrap()).collect()
}

#[test]
fn independent_endian_and_alignment_vectors() {
    for (version, order, expected) in [
        (Xcdr1, Little, "00010000 a500000000000000 0807060504030201 3412"),
        (Xcdr1, Big,    "00000000 a500000000000000 0102030405060708 1234"),
        (Xcdr2, Little, "00070000 a5000000 0807060504030201 3412"),
        (Xcdr2, Big,    "00060000 a5000000 0102030405060708 1234"),
    ] {
        let expected = hex(expected);
        let mut counter = Counter::new(version, order);
        counter.encapsulation().unwrap();
        counter.write_u8(0xa5).unwrap();
        counter.write_u64(0x0102030405060708).unwrap();
        counter.write_u16(0x1234).unwrap();
        assert_eq!(counter.len(), expected.len());
        let mut output = vec![0xcc; counter.len()];
        let mut writer = Writer::new(&mut output, version, order);
        writer.encapsulation().unwrap();
        writer.write_u8(0xa5).unwrap();
        writer.write_u64(0x0102030405060708).unwrap();
        writer.write_u16(0x1234).unwrap();
        assert_eq!(writer.bytes(), expected);
        let mut reader = Reader::new(&expected).unwrap();
        assert_eq!(reader.read_u8(), Ok(0xa5));
        assert_eq!(reader.read_u64(), Ok(0x0102030405060708));
        assert_eq!(reader.read_u16(), Ok(0x1234));
        assert_eq!(reader.position(), expected.len());
        assert_eq!(reader.read_u8(), Err(Error::Truncated));
        assert_eq!(reader.position(), expected.len());
        for cut in 0..expected.len() {
            if cut < 4 { assert!(matches!(Reader::new(&expected[..cut]), Err(Error::Invalid))); }
            else {
                let mut short = Reader::new(&expected[..cut]).unwrap();
                let result = short.read_u8().and_then(|_| short.read_u64()).and_then(|_| short.read_u16());
                assert_eq!(result, Err(Error::Truncated), "cut={cut}");
                assert!(short.position() <= cut);
            }
        }
    }
}

#[test]
fn floats_and_signed_values_have_independent_bytes() {
    for (order, expected) in [
        (Little, "00070000 ff01 0080 00000080 0000000000000080 0000c03f 00000000000002c0"),
        (Big,    "00060000 ff01 8000 80000000 8000000000000000 3fc00000 c002000000000000"),
    ] {
        let expected = hex(expected);
        let mut output = [0u8; 40];
        let mut w = Writer::new(&mut output, Xcdr2, order);
        w.encapsulation().unwrap();
        w.write_i8(-1).unwrap(); w.write_bool(true).unwrap();
        w.write_i16(i16::MIN).unwrap(); w.write_i32(i32::MIN).unwrap();
        w.write_i64(i64::MIN).unwrap(); w.write_f32(1.5).unwrap(); w.write_f64(-2.25).unwrap();
        assert_eq!(w.bytes(), expected);
        let mut r = Reader::new(&expected).unwrap();
        assert_eq!(r.read_i8(), Ok(-1)); assert_eq!(r.read_bool(), Ok(true));
        assert_eq!(r.read_i16(), Ok(i16::MIN)); assert_eq!(r.read_i32(), Ok(i32::MIN));
        assert_eq!(r.read_i64(), Ok(i64::MIN)); assert_eq!(r.read_f32(), Ok(1.5));
        assert_eq!(r.read_f64(), Ok(-2.25));
    }
}

#[test]
fn invalid_bool_is_consumed_but_truncation_is_not() {
    let input = [0, 7, 0, 0, 2];
    let mut r = Reader::new(&input).unwrap();
    assert_eq!(r.read_bool(), Err(Error::Invalid));
    assert_eq!(r.position(), 5);
    assert_eq!(r.read_bool(), Err(Error::Truncated));
    assert_eq!(r.position(), 5);
    for input in [[255,255,0,0], [0,4,0,0]] {
        assert!(matches!(Reader::new(&input), Err(Error::Invalid)));
    }
}

#[test]
fn failed_aligned_read_can_consume_padding() {
    let mut input = [0u8; 12]; input[1] = 1; input[4] = 9;
    let mut r = Reader::new(&input).unwrap(); r.read_u8().unwrap();
    assert_eq!(r.read_u64(), Err(Error::Truncated));
    assert_eq!(r.position(), 12);
    let mut r = Reader::new(&input[..11]).unwrap(); r.read_u8().unwrap();
    assert_eq!(r.read_u64(), Err(Error::Truncated));
    assert_eq!(r.position(), 11);
}

#[test]
fn fixed_empty_and_short_output_never_become_counting() {
    let mut empty = [];
    let mut w = Writer::new(&mut empty, Xcdr1, Little);
    assert_eq!(w.encapsulation(), Err(Error::Overflow));
    assert_eq!(w.write_u8(1), Err(Error::Overflow));
    assert!(w.bytes().is_empty());
    for length in 0..4 {
        let mut buffer = vec![0x55; length];
        let mut w = Writer::new(&mut buffer, Xcdr1, Big);
        assert_eq!(w.encapsulation(), Err(Error::Overflow));
        assert_eq!(w.len(), 0);
        assert_eq!(buffer, vec![0x55; length]);
    }
    let mut buffer = [0x55; 13];
    let mut w = Writer::new(&mut buffer[..12], Xcdr1, Little);
    w.encapsulation().unwrap(); w.write_u8(0xa5).unwrap();
    assert_eq!(w.write_u64(1), Err(Error::Overflow));
    assert_eq!(w.len(), 12); assert_eq!(w.position(), 8);
    assert_eq!(buffer[12], 0x55);
}

#[test]
fn count_then_fixed_requires_matching_capacity() {
    let mut c = Counter::new(Xcdr2, Little);
    c.encapsulation().unwrap(); c.write_u32(0x12345678).unwrap();
    assert_eq!(c.len(), 8);
    let mut buffer = [0u8; 7];
    let mut w = Writer::new(&mut buffer, Xcdr2, Little); w.encapsulation().unwrap();
    assert_eq!(w.write_u32(0x12345678), Err(Error::Overflow));
    assert_eq!(w.bytes(), [0,7,0,0]);
    let bytes = hex("00070000 78563412");
    assert_eq!(Reader::new(&bytes).unwrap().read_u32(), Ok(0x12345678));
}
