mod generated { include!(concat!(env!("CARGO_MANIFEST_DIR"), "/shapes.rs")); }
use generated::Types::{Sample, Point, Status, Inner::Ref};
use zidl_cdr_rust::{Counter, Writer, Reader, Version::*, ByteOrder::*, Error};

fn hex(s: &str) -> Vec<u8> {
    let text: String = s.split_whitespace().collect();
    (0..text.len()).step_by(2).map(|i| u8::from_str_radix(&text[i..i+2], 16).unwrap()).collect()
}
fn main() {
    for id in [2,3,8,9,10,11] {
        assert!(matches!(Reader::new(&[0,id,0,0,0,0,0,0]), Err(Error::Invalid)));
    }
    assert_eq!(Status::OK.0, 0); assert_eq!(Status::BAD.0, 1);
    let sample = Ref { value: Sample { tag: 0xa5, stamp: 0x0102030405060708,
        state: Status(0xfedcba98), pairs: [[1,2],[3,4]],
        position: Point { x: -1, y: 0x12345678 }, valid: true } };
    for (version, order, expected) in [
        (Xcdr1, Little, "00010000 a500000000000000 0807060504030201 98badcfe 0100020003000400 ffffffff78563412 01"),
        (Xcdr1, Big,    "00000000 a500000000000000 0102030405060708 fedcba98 0001000200030004 ffffffff12345678 01"),
        (Xcdr2, Little, "00070000 a5000000 0807060504030201 98badcfe 0100020003000400 ffffffff78563412 01"),
        (Xcdr2, Big,    "00060000 a5000000 0102030405060708 fedcba98 0001000200030004 ffffffff12345678 01"),
    ] {
        let expected = hex(expected);
        let mut count = Counter::new(version, order); count.encapsulation().unwrap();
        sample.encode(&mut count).unwrap(); assert_eq!(count.len(), expected.len());
        let mut bytes = vec![0xcc; count.len()]; let mut writer = Writer::new(&mut bytes, version, order);
        writer.encapsulation().unwrap(); sample.encode(&mut writer).unwrap();
        assert_eq!(writer.bytes(), expected);
        let mut reader = Reader::new(&expected).unwrap();
        assert_eq!(Ref::decode(&mut reader).unwrap(), sample);
        assert_eq!(reader.position(), expected.len());
        for cut in 4..expected.len() {
            let mut reader = Reader::new(&expected[..cut]).unwrap();
            assert_eq!(Ref::decode(&mut reader), Err(Error::Truncated));
            assert!(reader.position() <= cut);
        }
        let mut invalid = expected.clone(); *invalid.last_mut().unwrap() = 2;
        assert_eq!(Ref::decode(&mut Reader::new(&invalid).unwrap()), Err(Error::Invalid));
        let mut short = vec![0; expected.len()-1]; let mut writer = Writer::new(&mut short, version, order);
        writer.encapsulation().unwrap(); assert_eq!(sample.encode(&mut writer), Err(Error::Overflow));
    }
    let scalars = generated::Types::Scalars { a:-1,b:2,c:-3,d:4,e:-5,f:6,g:-7,h:8,i:1.5,j:-2.25,k:255,l:true };
    let expected = hex("00070000 ff02fdff 04000000 fbffffff 06000000 f9ffffffffffffff 0800000000000000 0000c03f 00000000000002c0 ff01");
    let mut bytes = [0; 50]; let mut w = Writer::new(&mut bytes, Xcdr2, Little);
    w.encapsulation().unwrap(); scalars.encode(&mut w).unwrap(); assert_eq!(w.bytes(), expected);
    assert_eq!(generated::Types::Scalars::decode(&mut Reader::new(&expected).unwrap()).unwrap(), scalars);
    let keyword = generated::r#mod::r#match { r#await: 7 };
    let mut bytes = [0; 8]; let mut w = Writer::new(&mut bytes, Xcdr2, Little);
    w.encapsulation().unwrap(); keyword.encode(&mut w).unwrap();
    assert_eq!(generated::r#mod::r#match::decode(&mut Reader::new(w.bytes()).unwrap()).unwrap(), keyword);
    println!("Generated final Rust codecs: vectors, unknown enum, nested arrays and failures passed");
}
