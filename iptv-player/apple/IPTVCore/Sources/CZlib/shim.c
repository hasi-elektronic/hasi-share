#include "CZlib.h"

int czlib_inflate_init2(z_streamp strm, int windowBits) {
    return inflateInit2(strm, windowBits);
}

int czlib_deflate_init2(z_streamp strm, int level, int windowBits) {
    return deflateInit2(strm, level, Z_DEFLATED, windowBits, 8, Z_DEFAULT_STRATEGY);
}
