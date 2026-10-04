#ifndef CZLIB_SHIM_H
#define CZLIB_SHIM_H

// Thin shim over the system zlib. zlib's init functions are macros, which Swift
// cannot import, so they are wrapped in real functions here.
#include <zlib.h>

/// inflateInit2 wrapper. windowBits 15+32 auto-detects gzip and zlib headers.
int czlib_inflate_init2(z_streamp strm, int windowBits);

/// deflateInit2 wrapper. windowBits 15+16 writes a gzip header.
int czlib_deflate_init2(z_streamp strm, int level, int windowBits);

#endif
