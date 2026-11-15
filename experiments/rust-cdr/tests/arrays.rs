use cdr_abi_experiment::{read_array, Error, Reader};
use std::{cell::Cell, rc::Rc};

struct Tracked(Rc<Cell<usize>>);
impl Drop for Tracked {
    fn drop(&mut self) { self.0.set(self.0.get() + 1); }
}

#[test]
fn partial_array_failure_drops_constructed_elements() {
    let bytes = [0, 7, 0, 0, 1, 2];
    let mut reader = Reader::new(&bytes).unwrap();
    let drops = Rc::new(Cell::new(0));
    let result: Result<[Tracked; 3], Error> = read_array(&mut reader, |r| {
        r.read_u8()?;
        Ok(Tracked(Rc::clone(&drops)))
    });
    assert!(matches!(result, Err(Error::Truncated)));
    assert_eq!(drops.get(), 2);
    assert_eq!(reader.position(), bytes.len());
}

#[test]
fn zero_length_array_reads_nothing() {
    let bytes = [0, 7, 0, 0];
    let mut reader = Reader::new(&bytes).unwrap();
    let values: [u8; 0] = read_array(&mut reader, |r| r.read_u8()).unwrap();
    assert!(values.is_empty());
    assert_eq!(reader.position(), 4);
}
