use cdr_abi_experiment::Reader;
fn main() {
    let mut bytes = [0,7,0,0,1]; let mut reader = Reader::new(&bytes).unwrap();
    bytes[4] = 9; let _ = reader.read_u8();
}
