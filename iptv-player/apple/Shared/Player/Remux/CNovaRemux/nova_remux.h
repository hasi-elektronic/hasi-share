// Thin C shim over libavformat/libavcodec (FFmpeg, LGPL-2.1, dynamic FFmpeg.framework) for the
// "Apple + Remux (Beta)" engine: MKV (cues) → HLS VOD with fragmented-MP4 segments for AVPlayer.
// Video is copied (H.264/HEVC); audio is copied (AAC, AC-3, E-AC-3) or transcoded to AAC.
//
// Not thread-safe: one NRContext is driven from ONE serial queue (`RemuxSession`). Only
// `nr_interrupt` may be called from any thread. The input callbacks may block (network).
#ifndef NOVA_REMUX_H
#define NOVA_REMUX_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct NRContext NRContext;

/// Reads up to `size` bytes; returns the count (> 0), 0 at end of input, < 0 on error/abort.
typedef int (*NRReadFn)(void *opaque, uint8_t *buf, int size);
/// whence: 0 SEEK_SET, 1 SEEK_CUR, 2 SEEK_END, NR_SEEK_SIZE → total size. Returns position/size or < 0.
typedef int64_t (*NRSeekFn)(void *opaque, int64_t offset, int whence);
#define NR_SEEK_SIZE 0x10000

/// Error codes besides negative AVERRORs.
#define NR_ERR_NO_VIDEO       (-0x4E520001)
#define NR_ERR_VIDEO_CODEC    (-0x4E520002)
#define NR_ERR_NO_INDEX       (-0x4E520003)
#define NR_ERR_RANGE          (-0x4E520004)

typedef struct NRInfo {
    double duration;            ///< seconds (playlist length)
    int width, height;
    double fps;
    char video_codec[16];       ///< "h264" / "hevc"
    char codecs[96];            ///< HLS CODECS attribute ("avc1.640028,mp4a.40.2")
    char video_range[8];        ///< "SDR" / "PQ" / "HLG"
    char audio_codec_in[24];    ///< source audio codec ("" = no audio)
    char audio_codec_out[16];   ///< "aac" / "ac3" / "eac3" ("" = no audio)
    char audio_language[8];
    int audio_transcoded;
    int audio_channels;         ///< output channels
    int audio_track_count;
    int64_t bitrate;            ///< bits/s estimate (BANDWIDTH)
    int segment_count;
    double target_duration;     ///< longest segment, seconds
    int64_t open_bytes_read;    ///< bytes read by nr_open (diagnostics)
} NRInfo;

typedef struct NRSegmentStats {
    int video_packets, audio_packets;
    double video_first_pts, video_end_pts;   ///< output timeline seconds (presentation)
    double audio_first_pts, audio_end_pts;
    double encode_ms;                        ///< audio transcode time
} NRSegmentStats;

/// Opens the input and builds the segment index. `audio_language`: preferred ISO 639 code or NULL.
/// Returns NULL and fills `err` on failure; `*code` gets the error code.
NRContext *nr_open(void *opaque, NRReadFn read_fn, NRSeekFn seek_fn, const char *audio_language,
                   double target_segment_seconds, int force_audio_transcode, int *code, char *err, int errlen);
void nr_get_info(const NRContext *ctx, NRInfo *info);
double nr_segment_start(const NRContext *ctx, int index);     ///< playlist time, seconds
double nr_segment_duration(const NRContext *ctx, int index);  ///< seconds
/// Init segment (ftyp + moov), generated together with media segment 0 (returned in `seg0` when not
/// NULL, so the first request is served from the cache). Caller frees both with nr_free.
int nr_init_segment(NRContext *ctx, uint8_t **data, size_t *size, uint8_t **seg0, size_t *seg0_size,
                    NRSegmentStats *seg0_stats);
/// Media segment `index` (moof + mdat). Caller frees with nr_free.
int nr_media_segment(NRContext *ctx, int index, uint8_t **data, size_t *size, NRSegmentStats *stats);
void nr_free(uint8_t *data);
/// Aborts the running nr_* call (any thread); `on = 0` clears the flag before the next call.
void nr_interrupt(NRContext *ctx, int on);
void nr_close(NRContext *ctx);
void nr_error_string(int code, char *buf, int len);
/// FFmpeg version + configuration (licence page / diagnostics).
const char *nr_ffmpeg_version(void);
const char *nr_ffmpeg_license(void);

#ifdef __cplusplus
}
#endif
#endif
