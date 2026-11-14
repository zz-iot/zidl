//! Experimental borrowed-buffer wrapper; not a public runtime API.
mod ffi;
use std::{ffi::c_int, mem::MaybeUninit};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error { Overflow, Truncated, Invalid, Native(c_int) }
fn status(code: c_int) -> Result<(), Error> {
    match code { 0 => Ok(()), -1 => Err(Error::Overflow), -2 => Err(Error::Truncated),
        -3 => Err(Error::Invalid), other => Err(Error::Native(other)) }
}
#[derive(Clone, Copy)]
pub enum Version { Xcdr1 = 1, Xcdr2 = 2 }
#[derive(Clone, Copy)]
pub enum ByteOrder { Little = 0, Big = 1 }

pub struct Writer<'a> { raw: ffi::Writer, buffer: &'a mut [u8] }
pub struct Counter { raw: ffi::Writer }
pub struct Reader<'a> { raw: ffi::Reader, _input: &'a [u8] }

impl<'a> Writer<'a> {
    pub fn new(buffer: &'a mut [u8], version: Version, order: ByteOrder) -> Self {
        let mut raw = MaybeUninit::<ffi::Writer>::uninit();
        // The initializer writes every field and retains only this exclusive buffer.
        // as_mut_ptr remains non-null for an empty slice, preserving fixed mode.
        let raw = unsafe {
            ffi::zidl_cdr_writer_init_fixed(raw.as_mut_ptr(), buffer.as_mut_ptr(), buffer.len(), version as c_int);
            let mut raw = raw.assume_init();
            ffi::zidl_cdr_writer_set_byte_order(&mut raw, order as c_int);
            raw
        };
        Self { raw, buffer }
    }
    pub fn bytes(&self) -> &[u8] { &self.buffer[..self.raw.len] }
}
impl Counter {
    pub fn new(version: Version, order: ByteOrder) -> Self {
        let mut raw = MaybeUninit::<ffi::Writer>::uninit();
        // Counting initialization fills every field and retains no output storage.
        let raw = unsafe {
            ffi::zidl_cdr_writer_init_counting(raw.as_mut_ptr(), version as c_int);
            let mut raw = raw.assume_init();
            ffi::zidl_cdr_writer_set_byte_order(&mut raw, order as c_int);
            raw
        };
        Self { raw }
    }
}
macro_rules! writer_ops {
    ($($name:ident : $ty:ty => $call:ident),*) => {
        pub fn encapsulation(&mut self) -> Result<(), Error> {
            // raw is initialized and its fixed borrow or counting mode remains valid.
            status(unsafe { ffi::zidl_cdr_write_encap(&mut self.raw) })
        }
        pub fn len(&self) -> usize { self.raw.len }
        pub fn is_empty(&self) -> bool { self.raw.len == 0 }
        pub fn position(&self) -> usize { self.raw.pos }
        $(pub fn $name(&mut self, value: $ty) -> Result<(), Error> {
            // Native writes enforce capacity; the wrapper never exposes mutable state.
            status(unsafe { ffi::$call(&mut self.raw, value) })
        })*
    }
}
impl Writer<'_> { writer_ops!(write_u8: u8 => zidl_cdr_write_u8,
        write_i8: i8 => zidl_cdr_write_i8,
        write_bool: bool => zidl_cdr_write_bool,
        write_u16: u16 => zidl_cdr_write_u16,
        write_i16: i16 => zidl_cdr_write_i16,
        write_u32: u32 => zidl_cdr_write_u32,
        write_i32: i32 => zidl_cdr_write_i32,
        write_f32: f32 => zidl_cdr_write_f32,
        write_u64: u64 => zidl_cdr_write_u64,
        write_i64: i64 => zidl_cdr_write_i64,
        write_f64: f64 => zidl_cdr_write_f64); }
impl Counter { writer_ops!(write_u8: u8 => zidl_cdr_write_u8,
        write_i8: i8 => zidl_cdr_write_i8,
        write_bool: bool => zidl_cdr_write_bool,
        write_u16: u16 => zidl_cdr_write_u16,
        write_i16: i16 => zidl_cdr_write_i16,
        write_u32: u32 => zidl_cdr_write_u32,
        write_i32: i32 => zidl_cdr_write_i32,
        write_f32: f32 => zidl_cdr_write_f32,
        write_u64: u64 => zidl_cdr_write_u64,
        write_i64: i64 => zidl_cdr_write_i64,
        write_f64: f64 => zidl_cdr_write_f64); }
impl<'a> Reader<'a> {
    pub fn new(input: &'a [u8]) -> Result<Self, Error> {
        let mut raw = MaybeUninit::<ffi::Reader>::uninit();
        // init reads only this immutable input and initializes all fields on success.
        status(unsafe { ffi::zidl_cdr_reader_init(raw.as_mut_ptr(), input.as_ptr(), input.len()) })?;
        Ok(Self { raw: unsafe { raw.assume_init() }, _input: input })
    }
    pub fn position(&self) -> usize { self.raw.pos }
    pub fn read_u8(&mut self) -> Result<u8, Error> {
        let mut value = MaybeUninit::<u8>::uninit();
        // The native reader checks bounds and writes a valid value only on success.
        status(unsafe { ffi::zidl_cdr_read_u8(&mut self.raw, value.as_mut_ptr()) })?;
        Ok(unsafe { value.assume_init() })
    }
    pub fn read_i8(&mut self) -> Result<i8, Error> {
        let mut value = MaybeUninit::<i8>::uninit();
        // The native reader checks bounds and writes a valid value only on success.
        status(unsafe { ffi::zidl_cdr_read_i8(&mut self.raw, value.as_mut_ptr()) })?;
        Ok(unsafe { value.assume_init() })
    }
    pub fn read_bool(&mut self) -> Result<bool, Error> {
        let mut value = MaybeUninit::<bool>::uninit();
        // The native reader checks bounds and writes a valid value only on success.
        status(unsafe { ffi::zidl_cdr_read_bool(&mut self.raw, value.as_mut_ptr()) })?;
        Ok(unsafe { value.assume_init() })
    }
    pub fn read_u16(&mut self) -> Result<u16, Error> {
        let mut value = MaybeUninit::<u16>::uninit();
        // The native reader checks bounds and writes a valid value only on success.
        status(unsafe { ffi::zidl_cdr_read_u16(&mut self.raw, value.as_mut_ptr()) })?;
        Ok(unsafe { value.assume_init() })
    }
    pub fn read_i16(&mut self) -> Result<i16, Error> {
        let mut value = MaybeUninit::<i16>::uninit();
        // The native reader checks bounds and writes a valid value only on success.
        status(unsafe { ffi::zidl_cdr_read_i16(&mut self.raw, value.as_mut_ptr()) })?;
        Ok(unsafe { value.assume_init() })
    }
    pub fn read_u32(&mut self) -> Result<u32, Error> {
        let mut value = MaybeUninit::<u32>::uninit();
        // The native reader checks bounds and writes a valid value only on success.
        status(unsafe { ffi::zidl_cdr_read_u32(&mut self.raw, value.as_mut_ptr()) })?;
        Ok(unsafe { value.assume_init() })
    }
    pub fn read_i32(&mut self) -> Result<i32, Error> {
        let mut value = MaybeUninit::<i32>::uninit();
        // The native reader checks bounds and writes a valid value only on success.
        status(unsafe { ffi::zidl_cdr_read_i32(&mut self.raw, value.as_mut_ptr()) })?;
        Ok(unsafe { value.assume_init() })
    }
    pub fn read_f32(&mut self) -> Result<f32, Error> {
        let mut value = MaybeUninit::<f32>::uninit();
        // The native reader checks bounds and writes a valid value only on success.
        status(unsafe { ffi::zidl_cdr_read_f32(&mut self.raw, value.as_mut_ptr()) })?;
        Ok(unsafe { value.assume_init() })
    }
    pub fn read_u64(&mut self) -> Result<u64, Error> {
        let mut value = MaybeUninit::<u64>::uninit();
        // The native reader checks bounds and writes a valid value only on success.
        status(unsafe { ffi::zidl_cdr_read_u64(&mut self.raw, value.as_mut_ptr()) })?;
        Ok(unsafe { value.assume_init() })
    }
    pub fn read_i64(&mut self) -> Result<i64, Error> {
        let mut value = MaybeUninit::<i64>::uninit();
        // The native reader checks bounds and writes a valid value only on success.
        status(unsafe { ffi::zidl_cdr_read_i64(&mut self.raw, value.as_mut_ptr()) })?;
        Ok(unsafe { value.assume_init() })
    }
    pub fn read_f64(&mut self) -> Result<f64, Error> {
        let mut value = MaybeUninit::<f64>::uninit();
        // The native reader checks bounds and writes a valid value only on success.
        status(unsafe { ffi::zidl_cdr_read_f64(&mut self.raw, value.as_mut_ptr()) })?;
        Ok(unsafe { value.assume_init() })
    }
}
/// Validation-only ABI fingerprint; field order follows the public C header.
pub fn layout() -> Vec<usize> {
    use std::mem::{size_of, align_of, offset_of};
    vec![size_of::<ffi::Writer>(), align_of::<ffi::Writer>(),
        offset_of!(ffi::Writer, buf), offset_of!(ffi::Writer, cap),
        offset_of!(ffi::Writer, len), offset_of!(ffi::Writer, pos),
        offset_of!(ffi::Writer, xcdr_version), offset_of!(ffi::Writer, byte_order),
        offset_of!(ffi::Writer, grow_fn), size_of::<ffi::Reader>(), align_of::<ffi::Reader>(),
        offset_of!(ffi::Reader, data), offset_of!(ffi::Reader, data_len),
        offset_of!(ffi::Reader, pos), offset_of!(ffi::Reader, byte_order),
        offset_of!(ffi::Reader, xcdr_version), offset_of!(ffi::Reader, is_pl_cdr)]
}
