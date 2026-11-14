use cdr_abi_experiment::Reader;
fn main() {
    let mut reader;
    { let bytes = [0,7,0,0,1]; reader = Reader::new(&bytes).unwrap(); }
    let _ = reader.read_u8();
}
