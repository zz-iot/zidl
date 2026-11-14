use cdr_abi_experiment::{Writer,Version,ByteOrder};
fn main() {
    let mut writer;
    { let mut bytes = [0;8]; writer = Writer::new(&mut bytes,Version::Xcdr2,ByteOrder::Little); }
    let _ = writer.encapsulation();
}
