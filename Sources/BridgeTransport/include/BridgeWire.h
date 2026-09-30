#ifndef AURALISCOPE_BRIDGE_WIRE_H
#define AURALISCOPE_BRIDGE_WIRE_H

// Tagged fields of protocol version 3 (Bridge/PROTOCOL.md), for C and C++: a writer into caller-owned memory and
// a reader over a received payload. No allocation, no locks. The Swift side has the same encoding in
// Sources/AnalysisCore/ResultProtocol.swift (WireWriter, WireReader).
//
//   field = tag u16 · kind u8 · flags u8 (0) · count u32 · count × size(kind) bytes · zero padding to 4 bytes

#include <stddef.h>
#include <stdint.h>
#include <string.h>

enum {
    ABR_KIND_U8 = 1, ABR_KIND_U32 = 2, ABR_KIND_U64 = 3, ABR_KIND_I64 = 4,
    ABR_KIND_F32 = 5, ABR_KIND_F64 = 6, ABR_KIND_UTF8 = 7, ABR_KIND_BYTES = 8,
};

static inline uint32_t abr_kind_size(uint8_t kind) {
    switch (kind) {
    case ABR_KIND_U8: case ABR_KIND_UTF8: case ABR_KIND_BYTES: return 1;
    case ABR_KIND_U32: case ABR_KIND_F32: return 4;
    case ABR_KIND_U64: case ABR_KIND_I64: case ABR_KIND_F64: return 8;
    default: return 0;
    }
}

// Apple platforms are little-endian; these keep the byte order explicit should that ever change.
static inline void abr_put16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static inline void abr_put32(uint8_t *p, uint32_t v) { for (int i = 0; i < 4; i++) p[i] = (uint8_t)(v >> (8 * i)); }
static inline void abr_put64(uint8_t *p, uint64_t v) { for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (8 * i)); }
static inline uint16_t abr_get16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static inline uint32_t abr_get32(const uint8_t *p) {
    uint32_t v = 0;
    for (int i = 3; i >= 0; i--) v = (v << 8) | p[i];
    return v;
}
static inline uint64_t abr_get64(const uint8_t *p) {
    uint64_t v = 0;
    for (int i = 7; i >= 0; i--) v = (v << 8) | p[i];
    return v;
}

typedef struct {
    uint8_t *base;
    size_t capacity;
    size_t used;
    int overflowed;   // a field did not fit: nothing of it was written; send nothing
} AbrWriter;

static inline AbrWriter abr_writer(void *base, size_t capacity) {
    AbrWriter w = {(uint8_t *)base, capacity, 0, 0};
    return w;
}

// Appends one field; `value` holds `count` elements already in little-endian order (or NULL for zeros).
static inline void abr_put_field(AbrWriter *w, uint16_t tag, uint8_t kind, uint32_t count, const void *value) {
    const size_t bytes = (size_t)count * abr_kind_size(kind), padded = (bytes + 3) & ~(size_t)3;
    if (w->overflowed || w->used + 8 + padded > w->capacity) { w->overflowed = 1; return; }
    uint8_t *p = w->base + w->used;
    abr_put16(p, tag);
    p[2] = kind;
    p[3] = 0;
    abr_put32(p + 4, count);
    if (bytes) { if (value) memcpy(p + 8, value, bytes); else memset(p + 8, 0, bytes); }
    if (padded > bytes) memset(p + 8 + bytes, 0, padded - bytes);
    w->used += 8 + padded;
}
static inline void abr_put_u32(AbrWriter *w, uint16_t tag, uint32_t v) {
    uint8_t b[4]; abr_put32(b, v); abr_put_field(w, tag, ABR_KIND_U32, 1, b);
}
static inline void abr_put_u64(AbrWriter *w, uint16_t tag, uint64_t v) {
    uint8_t b[8]; abr_put64(b, v); abr_put_field(w, tag, ABR_KIND_U64, 1, b);
}
static inline void abr_put_i64(AbrWriter *w, uint16_t tag, int64_t v) {
    uint8_t b[8]; abr_put64(b, (uint64_t)v); abr_put_field(w, tag, ABR_KIND_I64, 1, b);
}
static inline void abr_put_f64(AbrWriter *w, uint16_t tag, double v) {
    uint64_t bits; memcpy(&bits, &v, 8);
    uint8_t b[8]; abr_put64(b, bits); abr_put_field(w, tag, ABR_KIND_F64, 1, b);
}
static inline void abr_put_bytes(AbrWriter *w, uint16_t tag, const void *bytes, uint32_t count) {
    abr_put_field(w, tag, ABR_KIND_BYTES, count, bytes);
}
// UTF-8 text, cut to `limit` bytes at a character boundary.
static inline void abr_put_text(AbrWriter *w, uint16_t tag, const char *text, uint32_t limit) {
    size_t length = strlen(text);
    if (length > limit) {
        length = limit;
        while (length > 0 && ((unsigned char)text[length] & 0xC0) == 0x80) length--;
    }
    abr_put_field(w, tag, ABR_KIND_UTF8, (uint32_t)length, text);
}

typedef struct {
    uint16_t tag;
    uint8_t kind;
    uint32_t count;
    const uint8_t *value;
} AbrField;

typedef struct {
    const uint8_t *base;
    size_t length;
    size_t offset;
    int malformed;   // a field ran past the payload or had an unknown kind: reading stopped there
} AbrReader;

static inline AbrReader abr_reader(const void *payload, size_t length) {
    AbrReader r = {(const uint8_t *)payload, length, 0, 0};
    return r;
}

// Returns 1 and the next field, or 0 at the end (or at a malformed field, with `malformed` set).
static inline int abr_next_field(AbrReader *r, AbrField *field) {
    if (r->offset + 8 > r->length) {
        if (r->offset != r->length) r->malformed = 1;
        return 0;
    }
    const uint8_t *p = r->base + r->offset;
    const uint32_t size = abr_kind_size(p[2]), count = abr_get32(p + 4);
    if (size == 0 || count > (1u << 20)) { r->malformed = 1; return 0; }
    const size_t bytes = (size_t)count * size, padded = (bytes + 3) & ~(size_t)3;
    if (r->offset + 8 + padded > r->length) { r->malformed = 1; return 0; }
    field->tag = abr_get16(p);
    field->kind = p[2];
    field->count = count;
    field->value = p + 8;
    r->offset += 8 + padded;
    return 1;
}

// Typed reads: return 1 and the value when the field has the expected kind and one element (text: at most
// `size - 1` bytes, NUL-terminated; bytes: exactly `size`).
static inline int abr_field_u32(const AbrField *f, uint32_t *v) {
    if (f->kind != ABR_KIND_U32 || f->count != 1) return 0;
    *v = abr_get32(f->value);
    return 1;
}
static inline int abr_field_u64(const AbrField *f, uint64_t *v) {
    if (f->kind != ABR_KIND_U64 || f->count != 1) return 0;
    *v = abr_get64(f->value);
    return 1;
}
static inline int abr_field_i64(const AbrField *f, int64_t *v) {
    if (f->kind != ABR_KIND_I64 || f->count != 1) return 0;
    *v = (int64_t)abr_get64(f->value);
    return 1;
}
static inline int abr_field_f64(const AbrField *f, double *v) {
    if (f->kind != ABR_KIND_F64 || f->count != 1) return 0;
    const uint64_t bits = abr_get64(f->value);
    memcpy(v, &bits, 8);
    return 1;
}
static inline int abr_field_text(const AbrField *f, char *text, size_t size) {
    if (f->kind != ABR_KIND_UTF8 || size == 0 || f->count > size - 1) return 0;
    memcpy(text, f->value, f->count);
    text[f->count] = 0;
    return 1;
}
static inline int abr_field_bytes(const AbrField *f, void *bytes, size_t size) {
    if ((f->kind != ABR_KIND_BYTES && f->kind != ABR_KIND_U8) || f->count != size) return 0;
    memcpy(bytes, f->value, size);
    return 1;
}

#endif
