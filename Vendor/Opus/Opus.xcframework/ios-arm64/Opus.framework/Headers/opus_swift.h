// Swift can't call C's variadic functions, so libopus's opus_encoder_ctl and opus_decoder_ctl get one wrapper per
// argument shape. Written for Agent Hub (Apache License 2.0); not part of libopus.
#ifndef OPUS_SWIFT_H
#define OPUS_SWIFT_H
#include "opus.h"

static inline int opus_swift_encoder_set(OpusEncoder *encoder, int request, opus_int32 value) {
    return opus_encoder_ctl(encoder, request, value);
}

static inline int opus_swift_encoder_get(OpusEncoder *encoder, int request, opus_int32 *value) {
    return opus_encoder_ctl(encoder, request, value);
}

static inline int opus_swift_encoder_reset(OpusEncoder *encoder) {
    return opus_encoder_ctl(encoder, OPUS_RESET_STATE);
}

static inline int opus_swift_decoder_set(OpusDecoder *decoder, int request, opus_int32 value) {
    return opus_decoder_ctl(decoder, request, value);
}

static inline int opus_swift_decoder_get(OpusDecoder *decoder, int request, opus_int32 *value) {
    return opus_decoder_ctl(decoder, request, value);
}

static inline int opus_swift_decoder_reset(OpusDecoder *decoder) {
    return opus_decoder_ctl(decoder, OPUS_RESET_STATE);
}
#endif
