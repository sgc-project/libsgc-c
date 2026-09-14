#![doc = include_str!("../README.md")]
// The crate is a C ABI: every public function takes raw pointers because C has
// no other way to pass them, and each one checks them for null and writes an
// error message through `catch_unwind` instead of dereferencing blindly (see
// `sgc_advertised`, which validates `c`, `out` and `count` before writing).
// Clippy's `not_unsafe_ptr_arg_deref` wants those entry points marked `unsafe`,
// which would mean nothing to a C caller; the validation is the contract, and it
// is mirrored in `include/libsgc.h`.
#![allow(clippy::not_unsafe_ptr_arg_deref)]

pub mod ffi;
