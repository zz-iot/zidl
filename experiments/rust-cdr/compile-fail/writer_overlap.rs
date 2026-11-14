use cdr_abi_experiment::{Writer,Version,ByteOrder};
fn main() {
    let mut bytes = [0;8];
    let mut first = Writer::new(&mut bytes,Version::Xcdr2,ByteOrder::Little);
    let mut second = Writer::new(&mut bytes,Version::Xcdr2,ByteOrder::Little);
    let _ = first.encapsulation(); let _ = second.encapsulation();
}
