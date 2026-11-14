//! Private declarations checked against the installed C header by the layout probe.
use std::ffi::c_int;

#[repr(C)]
pub struct Writer {
    pub buf: *mut u8,
    pub cap: usize,
    pub len: usize,
    pub pos: usize,
    pub xcdr_version: c_int,
    pub byte_order: c_int,
    pub grow_fn: Option<unsafe extern "C" fn(*mut Writer, usize) -> c_int>,
}
#[repr(C)]
pub struct Reader {
    pub data: *const u8,
    pub data_len: usize,
    pub pos: usize,
    pub byte_order: c_int,
    pub xcdr_version: c_int,
    pub is_pl_cdr: c_int,
}
extern "C" {
    pub fn zidl_cdr_writer_init_fixed(w: *mut Writer, buf: *mut u8, cap: usize, version: c_int);
    pub fn zidl_cdr_writer_init_counting(w: *mut Writer, version: c_int);
    pub fn zidl_cdr_writer_set_byte_order(w: *mut Writer, order: c_int);
    pub fn zidl_cdr_write_encap(w: *mut Writer) -> c_int;
    pub fn zidl_cdr_reader_init(r: *mut Reader, data: *const u8, len: usize) -> c_int;
    pub fn zidl_cdr_write_u8(w: *mut Writer, value: u8) -> c_int;
    pub fn zidl_cdr_read_u8(r: *mut Reader, out: *mut u8) -> c_int;
    pub fn zidl_cdr_write_i8(w: *mut Writer, value: i8) -> c_int;
    pub fn zidl_cdr_read_i8(r: *mut Reader, out: *mut i8) -> c_int;
    pub fn zidl_cdr_write_bool(w: *mut Writer, value: bool) -> c_int;
    pub fn zidl_cdr_read_bool(r: *mut Reader, out: *mut bool) -> c_int;
    pub fn zidl_cdr_write_u16(w: *mut Writer, value: u16) -> c_int;
    pub fn zidl_cdr_read_u16(r: *mut Reader, out: *mut u16) -> c_int;
    pub fn zidl_cdr_write_i16(w: *mut Writer, value: i16) -> c_int;
    pub fn zidl_cdr_read_i16(r: *mut Reader, out: *mut i16) -> c_int;
    pub fn zidl_cdr_write_u32(w: *mut Writer, value: u32) -> c_int;
    pub fn zidl_cdr_read_u32(r: *mut Reader, out: *mut u32) -> c_int;
    pub fn zidl_cdr_write_i32(w: *mut Writer, value: i32) -> c_int;
    pub fn zidl_cdr_read_i32(r: *mut Reader, out: *mut i32) -> c_int;
    pub fn zidl_cdr_write_f32(w: *mut Writer, value: f32) -> c_int;
    pub fn zidl_cdr_read_f32(r: *mut Reader, out: *mut f32) -> c_int;
    pub fn zidl_cdr_write_u64(w: *mut Writer, value: u64) -> c_int;
    pub fn zidl_cdr_read_u64(r: *mut Reader, out: *mut u64) -> c_int;
    pub fn zidl_cdr_write_i64(w: *mut Writer, value: i64) -> c_int;
    pub fn zidl_cdr_read_i64(r: *mut Reader, out: *mut i64) -> c_int;
    pub fn zidl_cdr_write_f64(w: *mut Writer, value: f64) -> c_int;
    pub fn zidl_cdr_read_f64(r: *mut Reader, out: *mut f64) -> c_int;
}
