#pragma once
#include <stddef.h>
#define Spectral_HOP 512
#ifdef __cplusplus
extern "C" {
#endif
typedef struct spectral_stream spectral_stream;
int spectral_model_available(int game, int level);
spectral_stream* spectral_stream_create(int preset, int level, int channels, int unity);
void spectral_stream_destroy(spectral_stream* stream);
int spectral_stream_configure(spectral_stream* stream, int preset, int level);
// 0..1 scales positive log gains; attenuation is preserved. Serialized with process.
int spectral_stream_set_strength(spectral_stream* stream, float strength);
int spectral_stream_reset(spectral_stream* stream);
int spectral_stream_process(spectral_stream* stream, const float* input, float* output);
#ifdef __cplusplus
}
#endif
