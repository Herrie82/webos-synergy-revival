#include "denoise.h"
#include "modules/audio_processing/ns/noise_suppression.h"
#include <stddef.h>

// WebRTC float NS processes exactly one 10ms frame (fs/100 samples) per call, in the int16 value
// range as float (NOT normalized to +/-1). For <=16kHz it is a single band. The WhatsApp mic frame
// is 960 samples @ 16kHz (60ms) -> 6 sub-frames of 160.
static NsHandle *g_ns = NULL;
static int g_frame = 160; // fs/100

void wa_ns_start(int fs) {
	wa_ns_stop();
	if (fs <= 0) return;
	g_frame = fs / 100;
	g_ns = WebRtcNs_Create();
	if (g_ns) {
		if (WebRtcNs_Init(g_ns, (unsigned int)fs) != 0) { WebRtcNs_Free(g_ns); g_ns = NULL; return; }
		// policy 0..3 = mild..very aggressive. 2 balances noise removal against musical-noise/voice
		// artifacts on this analog mic; bump to 3 if the peer still hears too much floor.
		WebRtcNs_set_policy(g_ns, 2);
	}
}

void wa_ns_process(short *buf, int n) {
	if (!g_ns || g_frame <= 0) return;
	float in[480], out[480]; // max one 10ms frame @ 48kHz
	int off = 0;
	while (off + g_frame <= n) {
		int i;
		for (i = 0; i < g_frame; i++) in[i] = (float)buf[off + i];
		WebRtcNs_Analyze(g_ns, in);
		{
			const float *const bands_in[1] = { in };
			float *const bands_out[1] = { out };
			WebRtcNs_Process(g_ns, bands_in, 1, bands_out);
		}
		for (i = 0; i < g_frame; i++) {
			float v = out[i];
			if (v > 32767.0f) v = 32767.0f; else if (v < -32768.0f) v = -32768.0f;
			buf[off + i] = (short)v;
		}
		off += g_frame;
	}
	// any tail < one frame (rare short read) passes through un-denoised
}

void wa_ns_stop(void) {
	if (g_ns) { WebRtcNs_Free(g_ns); g_ns = NULL; }
}
