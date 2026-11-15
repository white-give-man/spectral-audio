#pragma once
#include <stddef.h>
#define Spectral_HOP 512
#define Spectral_EQ_BANDS 10
#define Spectral_EQ_MIN_HZ 20
#define Spectral_EQ_MAX_HZ 20000
#ifdef __cplusplus
extern "C" {
#endif
typedef struct spectral_stream spectral_stream;
int spectral_model_available(int game, int level);
spectral_stream* spectral_stream_create(int preset, int level, int channels, int unity);
void spectral_stream_destroy(spectral_stream* stream);
int spectral_stream_configure(spectral_stream* stream, int preset, int level);
// 0..2 scales positive log gains; attenuation is preserved. Serialized with process.
int spectral_stream_set_strength(spectral_stream* stream, float strength);
// 0 disables DRC; 1 selects the default curve, 2..5 numbered curves 1..4.
// Stereo-linked, before spectral analysis; serialized with process. No added delay.
int spectral_stream_set_drc(spectral_stream* stream, unsigned mode);
// Ten signed gains in hundredths of a dB (-600..600), or NULL for a flat curve.
// Serialized with process. Changes ramp between analysis frames.
int spectral_stream_set_eq(spectral_stream* stream, const int* bands);
// An optional frequency array uses 20..20000 Hz. Zero selects the band's default.
int spectral_stream_set_eq_frequencies(spectral_stream* stream, const int* bands, const int* frequencies_hz);
int spectral_stream_reset(spectral_stream* stream);
int spectral_stream_process(spectral_stream* stream, const float* input, float* output);
#ifdef __cplusplus
}
#endif
