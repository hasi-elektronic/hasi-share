// MKV → HLS/fMP4 remuxer (see nova_remux.h). Compiled only when the FFmpeg headers exist
// (apple/Vendor/FFmpeg/include, scripts/build-ffmpeg.sh).
#if __has_include(<libavformat/avformat.h>)
#include "nova_remux.h"

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/audio_fifo.h>
#include <libavutil/channel_layout.h>
#include <libavutil/mathematics.h>
#include <libavutil/opt.h>
#include <libavutil/time.h>
#include <libswresample/swresample.h>
#include <stdatomic.h>
#include <string.h>

#define NR_OUT_VIDEO_TB ((AVRational){1, 90000})
/// Constant decode-time shift of the video track (frames): dts = sorted pts − shift, so every
/// segment is continuous with its neighbours whatever order they are generated in.
#define NR_DTS_SHIFT_FRAMES 6
#define NR_AAC_FRAME 1024
#define NR_AAC_PREROLL_FRAMES 2

struct NRContext {
    AVFormatContext *fmt;
    AVIOContext *avio;
    void *opaque;
    NRReadFn read_fn;
    NRSeekFn seek_fn;
    _Atomic int interrupted;
    int64_t bytes_read;

    int vidx, aidx;
    AVStream *vst, *ast;
    int64_t k0;                 ///< first keyframe pts (video tb) = playlist time 0
    int64_t *keyframes;         ///< all index keyframes (video tb)
    int nb_keyframes;
    int64_t *bounds;            ///< segment boundaries (video tb), nb_segments + 1 (last = end)
    int nb_segments;
    double target_duration;
    int64_t frame_dur90;        ///< nominal frame duration, 90 kHz
    int64_t shift90;            ///< dts shift = global offset, 90 kHz

    // Audio output
    int audio_copy;             ///< 1 copy, 0 transcode
    AVCodecParameters *aout_par;
    int aout_rate;
    int aout_frame;             ///< samples per packet on the output grid
    int64_t a0;                 ///< audio grid anchor (audio tb) for copy mode
    AVChannelLayout aout_layout;

    char codecs[96];
    char video_range[8];
    char audio_language[8];
    int audio_track_count;
    int64_t bitrate;
    int64_t open_bytes;
};

// MARK: IO

static int nr_avio_read(void *opaque, uint8_t *buf, int size) {
    NRContext *c = opaque;
    if (atomic_load(&c->interrupted)) return AVERROR_EXIT;
    int n = c->read_fn(c->opaque, buf, size);
    if (n == 0) return AVERROR_EOF;
    if (n < 0) return atomic_load(&c->interrupted) ? AVERROR_EXIT : AVERROR(EIO);
    c->bytes_read += n;
    return n;
}

static int64_t nr_avio_seek(void *opaque, int64_t offset, int whence) {
    NRContext *c = opaque;
    if (whence & AVSEEK_SIZE) return c->seek_fn(c->opaque, 0, NR_SEEK_SIZE);
    return c->seek_fn(c->opaque, offset, whence & ~AVSEEK_FORCE);
}

static int nr_check_interrupt(void *opaque) {
    NRContext *c = opaque;
    return atomic_load(&c->interrupted);
}

void nr_interrupt(NRContext *ctx, int on) {
    if (ctx) atomic_store(&ctx->interrupted, on);
}

void nr_free(uint8_t *data) { av_free(data); }

void nr_error_string(int code, char *buf, int len) {
    switch (code) {
    case NR_ERR_NO_VIDEO: snprintf(buf, len, "no video stream"); return;
    case NR_ERR_VIDEO_CODEC: snprintf(buf, len, "video codec not remuxable"); return;
    case NR_ERR_NO_INDEX: snprintf(buf, len, "no keyframe index (cues)"); return;
    case NR_ERR_RANGE: snprintf(buf, len, "segment out of range"); return;
    default: av_strerror(code, buf, len);
    }
}

const char *nr_ffmpeg_version(void) { return av_version_info(); }
const char *nr_ffmpeg_license(void) { return avformat_license(); }

// MARK: Codec strings

static void nr_video_codec_string(const AVCodecParameters *p, char *out, size_t len) {
    const uint8_t *e = p->extradata;
    if (p->codec_id == AV_CODEC_ID_H264) {
        if (e && p->extradata_size >= 4 && e[0] == 1) {
            snprintf(out, len, "avc1.%02x%02x%02x", e[1], e[2], e[3]);
        } else {
            snprintf(out, len, "avc1.640028");
        }
        return;
    }
    // hvc1.<space><profile>.<compat reversed hex>.<tier><level>[.<constraint bytes>]
    if (e && p->extradata_size >= 13 && e[0] == 1) {
        int space = e[1] >> 6, tier = (e[1] >> 5) & 1, profile = e[1] & 0x1f;
        uint32_t compat = ((uint32_t)e[2] << 24) | ((uint32_t)e[3] << 16) | ((uint32_t)e[4] << 8) | e[5];
        uint32_t rev = 0;
        for (int i = 0; i < 32; i++) if (compat & (1u << i)) rev |= 1u << (31 - i);
        char buf[96];
        int n = snprintf(buf, sizeof buf, "hvc1.%s%d.%X.%c%d", space ? (space == 1 ? "A" : space == 2 ? "B" : "C") : "",
                         profile, rev, tier ? 'H' : 'L', e[12]);
        int last = -1;
        for (int i = 0; i < 6; i++) if (e[6 + i]) last = i;
        for (int i = 0; i <= last && n < (int)sizeof buf - 4; i++) n += snprintf(buf + n, sizeof buf - n, ".%02X", e[6 + i]);
        snprintf(out, len, "%s", buf);
        return;
    }
    snprintf(out, len, "hvc1.1.6.L93.B0");
}

static const char *nr_audio_codec_string(const AVCodecParameters *p) {
    switch (p->codec_id) {
    case AV_CODEC_ID_AC3: return "ac-3";
    case AV_CODEC_ID_EAC3: return "ec-3";
    case AV_CODEC_ID_AAC:
        if (p->profile == AV_PROFILE_AAC_HE) return "mp4a.40.5";
        if (p->profile == AV_PROFILE_AAC_HE_V2) return "mp4a.40.29";
        return "mp4a.40.2";
    default: return "mp4a.40.2";
    }
}

// MARK: Open

static int nr_cmp_i64(const void *a, const void *b) {
    int64_t x = *(const int64_t *)a, y = *(const int64_t *)b;
    return x < y ? -1 : x > y;
}

static int nr_pick_audio(AVFormatContext *fmt, int vidx, const char *lang, int *count) {
    int best = -1;
    *count = 0;
    for (unsigned i = 0; i < fmt->nb_streams; i++) {
        AVStream *st = fmt->streams[i];
        if (st->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) continue;
        (*count)++;
        if (lang && *lang && best < 0) {
            AVDictionaryEntry *t = av_dict_get(st->metadata, "language", NULL, 0);
            if (t && strncmp(t->value, lang, 2) == 0) best = (int)i;
        }
    }
    if (best >= 0) return best;
    int r = av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, vidx, NULL, 0);
    return r >= 0 ? r : -1;
}

/// Opens an AAC encoder for the transcode path (also used once at open for the moov extradata).
static AVCodecContext *nr_open_aac_encoder(const NRContext *c) {
    const AVCodec *enc = avcodec_find_encoder(AV_CODEC_ID_AAC);
    if (!enc) return NULL;
    AVCodecContext *e = avcodec_alloc_context3(enc);
    if (!e) return NULL;
    e->sample_rate = c->aout_rate;
    av_channel_layout_copy(&e->ch_layout, &c->aout_layout);
    e->sample_fmt = AV_SAMPLE_FMT_FLTP;
    e->bit_rate = c->aout_layout.nb_channels > 2 ? 384000 : 160000;
    e->time_base = (AVRational){1, c->aout_rate};
    e->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    if (avcodec_open2(e, enc, NULL) < 0) { avcodec_free_context(&e); return NULL; }
    return e;
}

NRContext *nr_open(void *opaque, NRReadFn read_fn, NRSeekFn seek_fn, const char *audio_language,
                   double target_segment_seconds, int force_audio_transcode, int *code, char *err, int errlen) {
    int ret = 0;
    NRContext *c = av_mallocz(sizeof *c);
    if (!c) { ret = AVERROR(ENOMEM); goto fail; }
    c->opaque = opaque;
    c->read_fn = read_fn;
    c->seek_fn = seek_fn;
    c->vidx = c->aidx = -1;
    atomic_store(&c->interrupted, 0);
    av_log_set_level(AV_LOG_ERROR);

    const int bufsize = 64 * 1024;
    uint8_t *buf = av_malloc(bufsize);
    if (!buf) { ret = AVERROR(ENOMEM); goto fail; }
    c->avio = avio_alloc_context(buf, bufsize, 0, c, nr_avio_read, NULL, nr_avio_seek);
    if (!c->avio) { av_free(buf); ret = AVERROR(ENOMEM); goto fail; }
    c->fmt = avformat_alloc_context();
    if (!c->fmt) { ret = AVERROR(ENOMEM); goto fail; }
    c->fmt->pb = c->avio;
    c->fmt->flags |= AVFMT_FLAG_CUSTOM_IO;
    c->fmt->interrupt_callback = (AVIOInterruptCB){nr_check_interrupt, c};
    c->fmt->probesize = 1 << 20;
    c->fmt->max_analyze_duration = AV_TIME_BASE / 2;
    if ((ret = avformat_open_input(&c->fmt, NULL, NULL, NULL)) < 0) { c->fmt = NULL; goto fail; }
    if ((ret = avformat_find_stream_info(c->fmt, NULL)) < 0) goto fail;

    c->vidx = av_find_best_stream(c->fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (c->vidx < 0) { ret = NR_ERR_NO_VIDEO; goto fail; }
    c->vst = c->fmt->streams[c->vidx];
    enum AVCodecID vid = c->vst->codecpar->codec_id;
    if (vid != AV_CODEC_ID_H264 && vid != AV_CODEC_ID_HEVC) { ret = NR_ERR_VIDEO_CODEC; goto fail; }

    c->aidx = nr_pick_audio(c->fmt, c->vidx, audio_language, &c->audio_track_count);
    for (unsigned i = 0; i < c->fmt->nb_streams; i++)
        if ((int)i != c->vidx && (int)i != c->aidx) c->fmt->streams[i]->discard = AVDISCARD_ALL;

    // Keyframe index: Matroska defers the cues until the first seek.
    if ((ret = av_seek_frame(c->fmt, c->vidx, c->vst->start_time != AV_NOPTS_VALUE ? c->vst->start_time : 0,
                             AVSEEK_FLAG_BACKWARD)) < 0) { ret = NR_ERR_NO_INDEX; goto fail; }
    int n = avformat_index_get_entries_count(c->vst);
    c->keyframes = av_malloc_array(n > 0 ? n : 1, sizeof(int64_t));
    if (!c->keyframes) { ret = AVERROR(ENOMEM); goto fail; }
    for (int i = 0; i < n; i++) {
        const AVIndexEntry *e = avformat_index_get_entry(c->vst, i);
        if (e && (e->flags & AVINDEX_KEYFRAME) && e->timestamp != AV_NOPTS_VALUE) c->keyframes[c->nb_keyframes++] = e->timestamp;
    }
    qsort(c->keyframes, c->nb_keyframes, sizeof(int64_t), nr_cmp_i64);
    int u = 0;
    for (int i = 0; i < c->nb_keyframes; i++)
        if (u == 0 || c->keyframes[i] != c->keyframes[u - 1]) c->keyframes[u++] = c->keyframes[i];
    c->nb_keyframes = u;
    if (c->nb_keyframes < 2) { ret = NR_ERR_NO_INDEX; goto fail; }
    c->k0 = c->keyframes[0];

    // Duration → end timestamp (video tb).
    int64_t end;
    AVRational vtb = c->vst->time_base;
    if (c->fmt->duration > 0) {
        int64_t start_us = c->fmt->start_time != AV_NOPTS_VALUE ? c->fmt->start_time : 0;
        end = av_rescale_q(start_us + c->fmt->duration, AV_TIME_BASE_Q, vtb);
    } else if (c->vst->duration > 0) {
        end = (c->vst->start_time != AV_NOPTS_VALUE ? c->vst->start_time : 0) + c->vst->duration;
    } else {
        end = c->keyframes[c->nb_keyframes - 1] + av_rescale_q(10, (AVRational){1, 1}, vtb);
    }

    // Segments: cut at the first index keyframe ≥ previous cut + target.
    if (target_segment_seconds <= 0) target_segment_seconds = 6;
    int64_t target = av_rescale_q((int64_t)(target_segment_seconds * 1000), (AVRational){1, 1000}, vtb);
    c->bounds = av_malloc_array(c->nb_keyframes + 1, sizeof(int64_t));
    if (!c->bounds) { ret = AVERROR(ENOMEM); goto fail; }
    c->bounds[0] = c->k0;
    int nb = 1;
    // Ramp-up: the first segments are short (≥ 1 s, 2 s, 3 s …) so the first bytes reach AVPlayer
    // sooner on slow links; then `target`.
    int64_t one_s = av_rescale_q(1, (AVRational){1, 1}, vtb);
    for (int i = 1; i < c->nb_keyframes; i++) {
        int64_t want = FFMIN(target, one_s * nb);
        if (c->keyframes[i] - c->bounds[nb - 1] >= want && c->keyframes[i] < end) c->bounds[nb++] = c->keyframes[i];
    }
    // A tiny tail segment (< 1/3 target) is merged into the previous one.
    if (nb > 1 && end - c->bounds[nb - 1] < target / 3) nb--;
    c->bounds[nb] = end > c->bounds[nb - 1] ? end : c->bounds[nb - 1] + target;
    c->nb_segments = nb;
    double maxd = 0;
    for (int i = 0; i < nb; i++) {
        double d = (c->bounds[i + 1] - c->bounds[i]) * av_q2d(vtb);
        if (d > maxd) maxd = d;
    }
    c->target_duration = maxd;
    // No/partial cues (e.g. a file written to a pipe): the index only holds the keyframes of the clusters
    // read so far → giant segments. Not remuxable without a full scan → caller falls back (VLCKit).
    if (maxd > 30) { ret = NR_ERR_NO_INDEX; goto fail; }

    AVRational fr = c->vst->avg_frame_rate.num > 0 ? c->vst->avg_frame_rate : c->vst->r_frame_rate;
    if (fr.num <= 0 || fr.den <= 0) fr = (AVRational){25, 1};
    c->frame_dur90 = av_rescale_q(1, av_inv_q(fr), NR_OUT_VIDEO_TB);
    if (c->frame_dur90 <= 0) c->frame_dur90 = 3600;
    c->shift90 = c->frame_dur90 * NR_DTS_SHIFT_FRAMES;

    // Audio plan.
    if (c->aidx >= 0) {
        c->ast = c->fmt->streams[c->aidx];
        AVCodecParameters *ap = c->ast->codecpar;
        AVDictionaryEntry *t = av_dict_get(c->ast->metadata, "language", NULL, 0);
        if (t) snprintf(c->audio_language, sizeof c->audio_language, "%s", t->value);
        int copyable = ap->codec_id == AV_CODEC_ID_AAC || ap->codec_id == AV_CODEC_ID_AC3 || ap->codec_id == AV_CODEC_ID_EAC3;
        c->audio_copy = copyable && !force_audio_transcode;
        c->aout_par = avcodec_parameters_alloc();
        if (!c->aout_par) { ret = AVERROR(ENOMEM); goto fail; }
        if (c->audio_copy) {
            avcodec_parameters_copy(c->aout_par, ap);
            c->aout_par->codec_tag = 0;
            c->aout_rate = ap->sample_rate > 0 ? ap->sample_rate : 48000;
            c->aout_frame = ap->frame_size > 0 ? ap->frame_size
                          : ap->codec_id == AV_CODEC_ID_AAC ? 1024 : 1536;
            c->a0 = c->ast->start_time != AV_NOPTS_VALUE ? c->ast->start_time
                  : av_rescale_q(c->k0, vtb, c->ast->time_base);
        } else {
            c->aout_rate = ap->sample_rate == 44100 ? 44100 : 48000;
            c->aout_frame = NR_AAC_FRAME;
            int ch = ap->ch_layout.nb_channels;
            av_channel_layout_default(&c->aout_layout, ch > 2 ? 6 : 2);
            AVCodecContext *e = nr_open_aac_encoder(c);
            if (!e) { ret = AVERROR_ENCODER_NOT_FOUND; goto fail; }
            avcodec_parameters_from_context(c->aout_par, e);
            avcodec_free_context(&e);
        }
    }

    char vcodec[48];
    nr_video_codec_string(c->vst->codecpar, vcodec, sizeof vcodec);
    if (c->aout_par)
        snprintf(c->codecs, sizeof c->codecs, "%s,%s", vcodec, nr_audio_codec_string(c->aout_par));
    else
        snprintf(c->codecs, sizeof c->codecs, "%s", vcodec);
    enum AVColorTransferCharacteristic trc = c->vst->codecpar->color_trc;
    snprintf(c->video_range, sizeof c->video_range, "%s",
             trc == AVCOL_TRC_SMPTE2084 ? "PQ" : trc == AVCOL_TRC_ARIB_STD_B67 ? "HLG" : "SDR");
    c->bitrate = c->fmt->bit_rate;
    if (c->bitrate <= 0) {
        int64_t size = avio_size(c->avio);
        double dur = (end - c->k0) * av_q2d(vtb);
        c->bitrate = size > 0 && dur > 0 ? (int64_t)(size * 8 / dur) : 5000000;
    }
    c->open_bytes = c->bytes_read;
    return c;

fail:
    if (code) *code = ret;
    if (err && errlen > 0) nr_error_string(ret, err, errlen);
    nr_close(c);
    return NULL;
}

void nr_get_info(const NRContext *c, NRInfo *info) {
    memset(info, 0, sizeof *info);
    AVRational vtb = c->vst->time_base;
    info->duration = (c->bounds[c->nb_segments] - c->k0) * av_q2d(vtb);
    info->width = c->vst->codecpar->width;
    info->height = c->vst->codecpar->height;
    AVRational fr = c->vst->avg_frame_rate.num > 0 ? c->vst->avg_frame_rate : c->vst->r_frame_rate;
    info->fps = fr.den > 0 ? av_q2d(fr) : 0;
    snprintf(info->video_codec, sizeof info->video_codec, "%s", avcodec_get_name(c->vst->codecpar->codec_id));
    snprintf(info->codecs, sizeof info->codecs, "%s", c->codecs);
    snprintf(info->video_range, sizeof info->video_range, "%s", c->video_range);
    if (c->ast) {
        snprintf(info->audio_codec_in, sizeof info->audio_codec_in, "%s", avcodec_get_name(c->ast->codecpar->codec_id));
        snprintf(info->audio_codec_out, sizeof info->audio_codec_out, "%s", avcodec_get_name(c->aout_par->codec_id));
        snprintf(info->audio_language, sizeof info->audio_language, "%s", c->audio_language);
        info->audio_transcoded = !c->audio_copy;
        info->audio_channels = c->aout_par->ch_layout.nb_channels;
    }
    info->audio_track_count = c->audio_track_count;
    info->bitrate = c->bitrate;
    info->segment_count = c->nb_segments;
    info->target_duration = c->target_duration;
    info->open_bytes_read = c->open_bytes;
}

double nr_segment_start(const NRContext *c, int i) {
    if (i < 0 || i >= c->nb_segments) return 0;
    return (c->bounds[i] - c->k0) * av_q2d(c->vst->time_base);
}

double nr_segment_duration(const NRContext *c, int i) {
    if (i < 0 || i >= c->nb_segments) return 0;
    return (c->bounds[i + 1] - c->bounds[i]) * av_q2d(c->vst->time_base);
}

// MARK: Segment generation

typedef struct NRPacketList {
    AVPacket **items;
    int count, capacity;
} NRPacketList;

static int nr_list_push(NRPacketList *l, AVPacket *pkt) {
    if (l->count == l->capacity) {
        int cap = l->capacity ? l->capacity * 2 : 256;
        AVPacket **items = av_realloc_array(l->items, cap, sizeof(AVPacket *));
        if (!items) return AVERROR(ENOMEM);
        l->items = items;
        l->capacity = cap;
    }
    AVPacket *copy = av_packet_clone(pkt);
    if (!copy) return AVERROR(ENOMEM);
    l->items[l->count++] = copy;
    return 0;
}

static void nr_list_free(NRPacketList *l) {
    for (int i = 0; i < l->count; i++) av_packet_free(&l->items[i]);
    av_freep(&l->items);
    l->count = l->capacity = 0;
}

/// Video timestamp (video tb) → output 90 kHz presentation time (offset by the dts shift so dts ≥ 0).
static int64_t nr_video_out(const NRContext *c, int64_t ts) {
    return av_rescale_q(ts - c->k0, c->vst->time_base, NR_OUT_VIDEO_TB) + c->shift90;
}

/// Output audio sample position of playlist time 0 (= the video offset in audio samples).
static int64_t nr_audio_offset(const NRContext *c) {
    return av_rescale_q(c->shift90, NR_OUT_VIDEO_TB, (AVRational){1, c->aout_rate});
}

/// Audio timestamp (audio tb) → output samples relative to playlist time 0 (no offset).
static int64_t nr_audio_rel(const NRContext *c, int64_t ts) {
    int64_t k0a = av_rescale_q(c->k0, c->vst->time_base, c->ast->time_base);
    return av_rescale_q(ts - k0a, c->ast->time_base, (AVRational){1, c->aout_rate});
}

typedef struct NRMuxer {
    AVFormatContext *oc;
    AVStream *ov, *oa;
} NRMuxer;

static int nr_mux_open(NRContext *c, NRMuxer *m) {
    int ret = avformat_alloc_output_context2(&m->oc, NULL, "mp4", NULL);
    if (ret < 0) return ret;
    m->ov = avformat_new_stream(m->oc, NULL);
    if (!m->ov) return AVERROR(ENOMEM);
    if ((ret = avcodec_parameters_copy(m->ov->codecpar, c->vst->codecpar)) < 0) return ret;
    m->ov->codecpar->codec_tag = c->vst->codecpar->codec_id == AV_CODEC_ID_HEVC ? MKTAG('h', 'v', 'c', '1')
                                                                                 : MKTAG('a', 'v', 'c', '1');
    m->ov->time_base = NR_OUT_VIDEO_TB;
    if (c->aout_par) {
        m->oa = avformat_new_stream(m->oc, NULL);
        if (!m->oa) return AVERROR(ENOMEM);
        if ((ret = avcodec_parameters_copy(m->oa->codecpar, c->aout_par)) < 0) return ret;
        m->oa->time_base = (AVRational){1, c->aout_rate};
        if (c->audio_language[0]) av_dict_set(&m->oa->metadata, "language", c->audio_language, 0);
    }
    if ((ret = avio_open_dyn_buf(&m->oc->pb)) < 0) return ret;
    m->oc->avoid_negative_ts = AVFMT_AVOID_NEG_TS_DISABLED;
    AVDictionary *opts = NULL;
    av_dict_set(&opts, "movflags", "frag_custom+empty_moov+delay_moov+default_base_moof+frag_discont+skip_trailer", 0);
    av_dict_set(&opts, "use_editlist", "0", 0);
    ret = avformat_write_header(m->oc, &opts);
    av_dict_free(&opts);
    return ret < 0 ? ret : 0;
}

/// Finishes the muxer and returns its whole output (ftyp + moov + moof + mdat).
static int nr_mux_close(NRMuxer *m, uint8_t **out, int *size) {
    int ret = 0;
    if (m->oc && m->oc->pb) {
        av_write_frame(m->oc, NULL);   // flush the fragment
        ret = av_write_trailer(m->oc);
        *size = avio_close_dyn_buf(m->oc->pb, out);
        m->oc->pb = NULL;
    }
    avformat_free_context(m->oc);
    m->oc = NULL;
    return ret;
}

static void nr_mux_abort(NRMuxer *m) {
    if (m->oc && m->oc->pb) {
        uint8_t *buf = NULL;
        avio_close_dyn_buf(m->oc->pb, &buf);
        av_free(buf);
        m->oc->pb = NULL;
    }
    avformat_free_context(m->oc);
    m->oc = NULL;
}

/// Offset of the first top-level box of `type` (or -1).
static int nr_find_box(const uint8_t *d, int size, const char *type) {
    int off = 0;
    while (off + 8 <= size) {
        uint32_t len = ((uint32_t)d[off] << 24) | ((uint32_t)d[off + 1] << 16) | ((uint32_t)d[off + 2] << 8) | d[off + 3];
        if (memcmp(d + off + 4, type, 4) == 0) return off;
        if (len < 8) return -1;
        off += (int)len;
    }
    return -1;
}

/// Audio transcoder state for one segment.
typedef struct NRTranscoder {
    AVCodecContext *dec, *enc;
    SwrContext *swr;
    AVAudioFifo *fifo;
    int64_t fifo_pos;      ///< output-sample position of the FIFO's first sample (rel. to playlist 0); INT64_MIN = unset
    int64_t next_in;       ///< next encoder input position
    AVFrame *frame, *eframe;
    AVPacket *epkt;
} NRTranscoder;

static void nr_tc_free(NRTranscoder *t) {
    avcodec_free_context(&t->dec);
    avcodec_free_context(&t->enc);
    swr_free(&t->swr);
    if (t->fifo) av_audio_fifo_free(t->fifo);
    t->fifo = NULL;
    av_frame_free(&t->frame);
    av_frame_free(&t->eframe);
    av_packet_free(&t->epkt);
}

static int nr_tc_open(NRContext *c, NRTranscoder *t) {
    memset(t, 0, sizeof *t);
    t->fifo_pos = INT64_MIN;
    const AVCodec *dc = avcodec_find_decoder(c->ast->codecpar->codec_id);
    if (!dc) return AVERROR_DECODER_NOT_FOUND;
    t->dec = avcodec_alloc_context3(dc);
    if (!t->dec) return AVERROR(ENOMEM);
    avcodec_parameters_to_context(t->dec, c->ast->codecpar);
    t->dec->pkt_timebase = c->ast->time_base;
    int ret = avcodec_open2(t->dec, dc, NULL);
    if (ret < 0) return ret;
    t->enc = nr_open_aac_encoder(c);
    if (!t->enc) return AVERROR_ENCODER_NOT_FOUND;
    t->fifo = av_audio_fifo_alloc(AV_SAMPLE_FMT_FLTP, c->aout_layout.nb_channels, 8192);
    t->frame = av_frame_alloc();
    t->eframe = av_frame_alloc();
    t->epkt = av_packet_alloc();
    if (!t->fifo || !t->frame || !t->eframe || !t->epkt) return AVERROR(ENOMEM);
    return 0;
}

/// Sends encoder output packets inside [g_start, g_end) to the muxer.
static int nr_tc_drain(NRContext *c, NRTranscoder *t, NRMuxer *m, int64_t g_start, int64_t g_end,
                       NRSegmentStats *st, int64_t *last_out) {
    int ret;
    while ((ret = avcodec_receive_packet(t->enc, t->epkt)) >= 0) {
        int64_t p = t->epkt->pts;   // relative output samples (encoder applies its priming delay)
        if (p >= g_start && p < g_end && p > *last_out) {
            *last_out = p;
            t->epkt->pts = t->epkt->dts = p + nr_audio_offset(c);
            t->epkt->duration = NR_AAC_FRAME;
            t->epkt->stream_index = m->oa->index;
            if (st) {
                double s = (double)t->epkt->pts / c->aout_rate;
                if (st->audio_packets == 0) st->audio_first_pts = s;
                st->audio_end_pts = s + (double)NR_AAC_FRAME / c->aout_rate;
                st->audio_packets++;
            }
            if ((ret = av_write_frame(m->oc, t->epkt)) < 0) { av_packet_unref(t->epkt); return ret; }
        }
        av_packet_unref(t->epkt);
    }
    return ret == AVERROR(EAGAIN) || ret == AVERROR_EOF ? 0 : ret;
}

/// Feeds whole 1024-sample frames from the FIFO (positions on the grid) into the encoder.
static int nr_tc_encode_fifo(NRContext *c, NRTranscoder *t, NRMuxer *m, int64_t g_start, int64_t g_end,
                             int64_t in_end, NRSegmentStats *st, int64_t *last_out, int flush) {
    int ret;
    while (av_audio_fifo_size(t->fifo) >= NR_AAC_FRAME && t->next_in < in_end) {
        AVFrame *f = t->eframe;
        av_frame_unref(f);
        f->nb_samples = NR_AAC_FRAME;
        f->format = AV_SAMPLE_FMT_FLTP;
        f->sample_rate = c->aout_rate;
        av_channel_layout_copy(&f->ch_layout, &c->aout_layout);
        if ((ret = av_frame_get_buffer(f, 0)) < 0) return ret;
        av_audio_fifo_read(t->fifo, (void **)f->data, NR_AAC_FRAME);
        f->pts = t->next_in;
        t->next_in += NR_AAC_FRAME;
        t->fifo_pos += NR_AAC_FRAME;
        if ((ret = avcodec_send_frame(t->enc, f)) < 0) return ret;
        if ((ret = nr_tc_drain(c, t, m, g_start, g_end, st, last_out)) < 0) return ret;
    }
    if (flush) {
        avcodec_send_frame(t->enc, NULL);
        if ((ret = nr_tc_drain(c, t, m, g_start, g_end, st, last_out)) < 0) return ret;
    }
    return 0;
}

/// Decodes one packet (NULL = flush) and appends resampled audio to the FIFO, aligned so that the
/// FIFO head sits on the encoder grid (`in_start`).
static int nr_tc_decode(NRContext *c, NRTranscoder *t, AVPacket *pkt, int64_t in_start) {
    int ret = avcodec_send_packet(t->dec, pkt);
    if (ret < 0 && ret != AVERROR(EAGAIN) && ret != AVERROR_EOF) return 0;   // skip a corrupt packet
    while ((ret = avcodec_receive_frame(t->dec, t->frame)) >= 0) {
        AVFrame *fr = t->frame;
        if (!t->swr) {
            ret = swr_alloc_set_opts2(&t->swr, &c->aout_layout, AV_SAMPLE_FMT_FLTP, c->aout_rate,
                                      &fr->ch_layout, fr->format, fr->sample_rate, 0, NULL);
            if (ret < 0 || (ret = swr_init(t->swr)) < 0) { av_frame_unref(fr); return ret; }
        }
        int64_t ts = fr->best_effort_timestamp != AV_NOPTS_VALUE ? fr->best_effort_timestamp : fr->pts;
        int max_out = swr_get_out_samples(t->swr, fr->nb_samples);
        uint8_t **out = NULL;
        if ((ret = av_samples_alloc_array_and_samples(&out, NULL, c->aout_layout.nb_channels, max_out,
                                                      AV_SAMPLE_FMT_FLTP, 0)) < 0) { av_frame_unref(fr); return ret; }
        int got = swr_convert(t->swr, out, max_out, (const uint8_t **)fr->extended_data, fr->nb_samples);
        if (got > 0) {
            int skip = 0;
            if (t->fifo_pos == INT64_MIN && ts != AV_NOPTS_VALUE) {
                int64_t pos = nr_audio_rel(c, ts);
                if (pos > in_start) {
                    // Input starts after the grid start (beginning of the file): pad with silence.
                    int pad = (int)FFMIN(pos - in_start, 48000 * 2);
                    uint8_t **sil = NULL;
                    if (av_samples_alloc_array_and_samples(&sil, NULL, c->aout_layout.nb_channels, pad, AV_SAMPLE_FMT_FLTP, 0) >= 0) {
                        av_samples_set_silence(sil, 0, pad, c->aout_layout.nb_channels, AV_SAMPLE_FMT_FLTP);
                        av_audio_fifo_write(t->fifo, (void **)sil, pad);
                        av_freep(&sil[0]);
                        av_freep(&sil);
                    }
                    t->fifo_pos = in_start;
                } else {
                    skip = (int)FFMIN(in_start - pos, got);
                    t->fifo_pos = in_start;
                    if (skip == got) t->fifo_pos = INT64_MIN;   // whole frame before the grid start
                }
                t->next_in = in_start;
            }
            if (t->fifo_pos != INT64_MIN && got > skip) {
                void *planes[8];
                for (int ch = 0; ch < c->aout_layout.nb_channels && ch < 8; ch++) planes[ch] = (float *)out[ch] + skip;
                av_audio_fifo_write(t->fifo, planes, got - skip);
            }
        }
        av_freep(&out[0]);
        av_freep(&out);
        av_frame_unref(fr);
    }
    return 0;
}

/// Index of the last keyframe strictly before `ts` (or 0).
static int nr_keyframe_before(const NRContext *c, int64_t ts) {
    int lo = 0, hi = c->nb_keyframes - 1, best = 0;
    while (lo <= hi) {
        int mid = (lo + hi) / 2;
        if (c->keyframes[mid] < ts) { best = mid; lo = mid + 1; } else hi = mid - 1;
    }
    return best;
}

/// Generates segment `index` with the full muxer output in `*out` (caller splits init / media).
static int nr_generate(NRContext *c, int index, uint8_t **out, int *out_size, NRSegmentStats *stats) {
    if (index < 0 || index >= c->nb_segments) return NR_ERR_RANGE;
    AVRational vtb = c->vst->time_base;
    int last = index == c->nb_segments - 1;
    int64_t start = c->bounds[index];
    int64_t end = last ? INT64_MAX : c->bounds[index + 1];
    int64_t end_ts = c->bounds[index + 1];
    int transcode = c->ast && !c->audio_copy;
    int64_t audio_margin = av_rescale_q(transcode ? 150 : 0, (AVRational){1, 1000}, vtb);
    int64_t safety = av_rescale_q(8, (AVRational){1, 1}, vtb);

    // Audio grid range (relative output samples) of this segment.
    int64_t a_start = 0, a_end = INT64_MAX, a_in_start = 0;
    if (c->ast) {
        int64_t rel_s = av_rescale_q(start - c->k0, vtb, (AVRational){1, c->aout_rate});
        int64_t rel_e = av_rescale_q(end_ts - c->k0, vtb, (AVRational){1, c->aout_rate});
        int64_t f = c->aout_frame;
        a_start = index == 0 ? 0 : ((rel_s + f - 1) / f) * f;
        a_end = last ? INT64_MAX : ((rel_e + f - 1) / f) * f;
        a_in_start = a_start - NR_AAC_PREROLL_FRAMES * NR_AAC_FRAME;
    }

    // Seek: the boundary keyframe, or (transcode) an earlier keyframe for the decoder/encoder preroll.
    // An aborted job (interrupt → AVERROR_EXIT) leaves a sticky error on the AVIOContext.
    c->avio->error = 0;
    c->avio->eof_reached = 0;
    int64_t seek_ts = start;
    if (transcode && index > 0) seek_ts = c->keyframes[nr_keyframe_before(c, start - av_rescale_q(100, (AVRational){1, 1000}, vtb))];
    int ret = av_seek_frame(c->fmt, c->vidx, seek_ts, AVSEEK_FLAG_BACKWARD);
    if (ret < 0) return ret;

    NRMuxer m = {0};
    NRPacketList video = {0};
    NRTranscoder tc = {0};
    AVPacket *pkt = av_packet_alloc();
    int64_t *sorted = NULL;
    if (!pkt) { ret = AVERROR(ENOMEM); goto done; }
    if ((ret = nr_mux_open(c, &m)) < 0) goto done;
    if (transcode && (ret = nr_tc_open(c, &tc)) < 0) goto done;

    int vstarted = 0, vdone = 0, adone = c->ast ? 0 : 1;
    int64_t last_audio_out = INT64_MIN;
    double enc_ms = 0;
    for (;;) {
        if (atomic_load(&c->interrupted)) { ret = AVERROR_EXIT; goto done; }
        ret = av_read_frame(c->fmt, pkt);
        if (ret == AVERROR_EOF) { ret = 0; break; }
        if (ret < 0) goto done;
        int64_t ts = pkt->pts != AV_NOPTS_VALUE ? pkt->pts : pkt->dts;
        if (pkt->stream_index == c->vidx) {
            if (ts == AV_NOPTS_VALUE) { av_packet_unref(pkt); continue; }
            int key = pkt->flags & AV_PKT_FLAG_KEY;
            if (!vstarted) {
                if (key && ts >= start) vstarted = 1;
                else if (ts > start + safety) vstarted = 1;   // broken index: take what comes
            }
            if (vstarted && !vdone) {
                if (key && ts >= end) vdone = 1;
                else if ((ret = nr_list_push(&video, pkt)) < 0) goto done;
            }
            if (vdone && ts > end_ts + safety) adone = 1;
        } else if (pkt->stream_index == c->aidx && ts != AV_NOPTS_VALUE) {
            int64_t ts_v = av_rescale_q(ts, c->ast->time_base, vtb);
            if (c->audio_copy) {
                int64_t f = c->aout_frame;
                int64_t a0rel = nr_audio_rel(c, c->a0);
                int64_t rel = nr_audio_rel(c, ts);
                int64_t n = (int64_t)llround((double)(rel - a0rel) / f);
                int64_t snapped = a0rel + n * f;   // sample-exact grid anchored at the first audio packet
                // Membership by the ORIGINAL timestamp (the demuxer drops audio before the seek keyframe,
                // so a packet rounded across the boundary must stay in the segment of its source time).
                if (!last && ts_v >= end_ts) adone = 1;
                else if (ts_v >= start && snapped >= 0 && snapped > last_audio_out) {
                    last_audio_out = snapped;
                    pkt->pts = pkt->dts = snapped + nr_audio_offset(c);
                    pkt->duration = f;
                    pkt->stream_index = m.oa->index;
                    pkt->pos = -1;
                    if (stats) {
                        double s = (double)pkt->pts / c->aout_rate;
                        if (stats->audio_packets == 0) stats->audio_first_pts = s;
                        stats->audio_end_pts = s + (double)f / c->aout_rate;
                        stats->audio_packets++;
                    }
                    if ((ret = av_write_frame(m.oc, pkt)) < 0) goto done;
                }
            } else {
                if (ts_v >= end_ts + audio_margin && !last) adone = 1;
                else {
                    int64_t t0 = av_gettime_relative();
                    if ((ret = nr_tc_decode(c, &tc, pkt, a_in_start)) < 0) goto done;
                    int64_t in_end = last ? INT64_MAX : a_end + 2 * NR_AAC_FRAME;
                    if (tc.fifo_pos != INT64_MIN &&
                        (ret = nr_tc_encode_fifo(c, &tc, &m, a_start, a_end, in_end, stats, &last_audio_out, 0)) < 0) goto done;
                    enc_ms += (av_gettime_relative() - t0) / 1000.0;
                }
            }
        }
        av_packet_unref(pkt);
        if (vdone && adone) break;
    }
    if (transcode && tc.dec) {
        int64_t t0 = av_gettime_relative();
        nr_tc_decode(c, &tc, NULL, a_in_start);
        if (tc.fifo_pos != INT64_MIN) {
            // Pad the tail so the last grid frame is complete, then flush the encoder (end of file only).
            if (last) {
                int rem = av_audio_fifo_size(tc.fifo) % NR_AAC_FRAME;
                if (rem) {
                    int pad = NR_AAC_FRAME - rem;
                    uint8_t **sil = NULL;
                    if (av_samples_alloc_array_and_samples(&sil, NULL, c->aout_layout.nb_channels, pad, AV_SAMPLE_FMT_FLTP, 0) >= 0) {
                        av_samples_set_silence(sil, 0, pad, c->aout_layout.nb_channels, AV_SAMPLE_FMT_FLTP);
                        av_audio_fifo_write(tc.fifo, (void **)sil, pad);
                        av_freep(&sil[0]);
                        av_freep(&sil);
                    }
                }
            }
            int64_t in_end = last ? INT64_MAX : a_end + 2 * NR_AAC_FRAME;
            if ((ret = nr_tc_encode_fifo(c, &tc, &m, a_start, a_end, in_end, stats, &last_audio_out, 1)) < 0) goto done;
        }
        enc_ms += (av_gettime_relative() - t0) / 1000.0;
    }
    if (stats) stats->encode_ms = enc_ms;

    // Video: dts = sorted pts − constant shift → continuous decode timeline across segments.
    if (video.count > 0) {
        sorted = av_malloc_array(video.count, sizeof(int64_t));
        if (!sorted) { ret = AVERROR(ENOMEM); goto done; }
        for (int i = 0; i < video.count; i++) sorted[i] = nr_video_out(c, video.items[i]->pts);
        qsort(sorted, video.count, sizeof(int64_t), nr_cmp_i64);
        int64_t seg_end_out = last ? sorted[video.count - 1] + c->frame_dur90 : nr_video_out(c, end_ts);
        int64_t shift = c->shift90;
        for (int i = 0; i < video.count; i++) {
            int64_t p = nr_video_out(c, video.items[i]->pts);
            if (sorted[i] - shift > p) shift = sorted[i] - p;   // deeper reordering than planned
        }
        if (shift != c->shift90) av_log(NULL, AV_LOG_WARNING, "remux: segment %d needs dts shift %lld\n", index, (long long)shift);
        for (int i = 0; i < video.count; i++) {
            AVPacket *p = video.items[i];
            p->pts = nr_video_out(c, p->pts);
            p->dts = sorted[i] - shift;
            int64_t next_dts = i + 1 < video.count ? sorted[i + 1] - shift : seg_end_out - shift;
            p->duration = next_dts - p->dts > 0 ? next_dts - p->dts : c->frame_dur90;
            p->stream_index = m.ov->index;
            p->pos = -1;
            if (stats) {
                double s = (double)p->pts / 90000.0;
                if (stats->video_packets == 0 || s < stats->video_first_pts) stats->video_first_pts = s;
                double e = (double)seg_end_out / 90000.0;
                stats->video_end_pts = e;
                stats->video_packets++;
            }
            if ((ret = av_write_frame(m.oc, p)) < 0) goto done;
        }
    }
    ret = nr_mux_close(&m, out, out_size);

done:
    if (m.oc) nr_mux_abort(&m);
    nr_tc_free(&tc);
    nr_list_free(&video);
    av_free(sorted);
    av_packet_free(&pkt);
    return ret;
}

int nr_init_segment(NRContext *c, uint8_t **data, size_t *size, uint8_t **seg0, size_t *seg0_size,
                    NRSegmentStats *seg0_stats) {
    uint8_t *buf = NULL;
    int len = 0;
    if (seg0_stats) memset(seg0_stats, 0, sizeof *seg0_stats);
    int ret = nr_generate(c, 0, &buf, &len, seg0_stats);
    if (ret < 0) { av_free(buf); return ret; }
    int moof = nr_find_box(buf, len, "moof");
    if (moof <= 0) { av_free(buf); return AVERROR_BUG; }
    *data = av_malloc(moof);
    if (!*data) { av_free(buf); return AVERROR(ENOMEM); }
    memcpy(*data, buf, moof);
    *size = (size_t)moof;
    if (seg0 && seg0_size) {
        *seg0 = av_malloc(len - moof);
        if (*seg0) {
            memcpy(*seg0, buf + moof, len - moof);
            *seg0_size = (size_t)(len - moof);
        }
    }
    av_free(buf);
    return 0;
}

int nr_media_segment(NRContext *c, int index, uint8_t **data, size_t *size, NRSegmentStats *stats) {
    uint8_t *buf = NULL;
    int len = 0;
    if (stats) memset(stats, 0, sizeof *stats);
    int ret = nr_generate(c, index, &buf, &len, stats);
    if (ret < 0) { av_free(buf); return ret; }
    int moof = nr_find_box(buf, len, "moof");
    if (moof < 0) { av_free(buf); return AVERROR_BUG; }
    *data = av_malloc(len - moof);
    if (!*data) { av_free(buf); return AVERROR(ENOMEM); }
    memcpy(*data, buf + moof, len - moof);
    *size = (size_t)(len - moof);
    av_free(buf);
    return 0;
}

void nr_close(NRContext *c) {
    if (!c) return;
    if (c->fmt) avformat_close_input(&c->fmt);
    if (c->avio) {
        av_freep(&c->avio->buffer);
        avio_context_free(&c->avio);
    }
    avcodec_parameters_free(&c->aout_par);
    av_channel_layout_uninit(&c->aout_layout);
    av_free(c->keyframes);
    av_free(c->bounds);
    av_free(c);
}
#endif
