#include <owi.h>

__attribute__((import_module("summaries"), import_name("alloc"))) void *
owi_malloc(void *, unsigned int);
__attribute__((import_module("summaries"), import_name("dealloc"))) void
owi_free(void *);

__attribute__((import_module("symbolic"), import_name("i8_symbol"))) char
owi_i8(void);
__attribute__((import_module("symbolic"), import_name("i32_symbol"))) int
owi_i32(void);
__attribute__((import_module("symbolic"), import_name("i64_symbol"))) long long
owi_i64(void);
__attribute__((import_module("symbolic"), import_name("f32_symbol"))) float
owi_f32(void);
__attribute__((import_module("symbolic"), import_name("f64_symbol"))) double
owi_f64(void);

__attribute__((import_module("symbolic"), import_name("assume"))) void
owi_assume(int);
__attribute__((import_module("symbolic"), import_name("assert"))) void
owi_assert(int);

__attribute__((weak, import_module("symbolic"), import_name("assume"))) void
assume(int);