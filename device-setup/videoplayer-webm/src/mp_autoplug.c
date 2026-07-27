/* LD_PRELOAD shim for webOS media-pipeline.real (SURGICAL).
 *
 * !!! DISABLED BY DEFAULT -- THIS SHIM BREAKS H.264 (mp4) VIDEO PLAYBACK. !!!
 * Verified on device (clean-boot A/B, 2026-07): with libmp-autoplug.so preloaded into media-pipeline.real,
 * H.264 video *media sessions are never created* (videoplayer/WebKit <video> spins; no MediaPlayerSession
 * ::load; the resource arbiter logs "requestPipeline restore timeout" / "unsent QueryName"). With the shim
 * OFF, the same mp4 decodes and plays via the Snapdragon S3 OMX hardware decoder. The break is NOT in
 * my_select (rewriting it did not help -- my_select never even runs for the video pad); it is something
 * about the LD_PRELOAD's presence in the video-session path that this surgical version could not isolate.
 * AUDIO sessions are unaffected. Since received IM videos are ALL H.264 mp4 (WhatsApp/Teams/Signal/Telegram)
 * and NONE are WebM, the shim's only benefit (WebM/VP9 in the general video player) does not apply to
 * messaging, so it is kept OFF (media-pipeline.wrapper.orig / stock). Only enable if you specifically need
 * WebM in the stock Video player AND accept that mp4 video will break. See device-setup/videoplayer-webm/README.md.
 *
 * Goal: make the media server's decodebin use the SOFTWARE vp8dec/vp9dec for WebM (VP8/VP9) while the
 * H.264-only SoC hardware decoder (palmvideodecoder) keeps handling mp4/H.264 (and everything else)
 * exactly as stock.
 *
 * We intercept decodebin's "autoplug-select" (registered via g_signal_connect_data) and install our own
 * my_select, which returns a GstAutoplugSelectResult directly:
 *   - VP8/VP9 caps + palmvideodecoder factory -> SKIP (the H.264-only hardware decoder chokes on VP9,
 *     "PalmOmxVideoDecoder ... chain error -2" -> endless buffering), so decodebin falls to vp8/vp9dec.
 *   - VP8/VP9 caps + any other factory (vp8dec/vp9dec) -> TRY.
 *   - everything else (H.264 -> palmvideodecoder, audio, ...) -> TRY (decodebin's default).
 *
 * REGRESSION FIX: the previous version DEFERRED the non-VP8/VP9 case to the ORIGINAL autoplug-select
 * binding (autoplugSelectBinding, a boost::signals2 trampoline captured from g_signal_connect_data).
 * Calling that binding directly broke the H.264 pipeline BEFORE autoplug even completed -- mp4 video
 * stopped playing entirely (the pipeline died before my_select ran on the video pad, /tmp/mp-shim.log
 * stayed empty, WebKit's <video> stalled at networkState=3 NO_SOURCE). The README's "mp3/mp4 still play
 * normally" claim was therefore WRONG. We now NEVER call the original binding: returning TRY(0) matches
 * decodebin's default and the stock (no-shim) behaviour that plays mp4/mp3 fine, so hardware H.264 is
 * untouched while VP8/VP9 still route to software.
 *
 * We must NOT touch autoplug-continue (its binding has a vtable side effect; replacing it crashes).
 *
 * Self-contained: no glib/gst headers (that dev header tree is gone). We declare the handful of glib
 * types and the few gst accessor functions we call; the symbols resolve at load time inside
 * media-pipeline.real (which has libglib-2.0 / libgstreamer-0.10 loaded).
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>

/* --- minimal glib/gst type + function declarations (glib-2.0 / gstreamer-0.10 ABI) --- */
typedef unsigned long gulong;
typedef void *gpointer;
typedef int gint;
typedef char gchar;
typedef int gboolean;
typedef void (*GCallback)(void);
typedef void (*GClosureNotify)(gpointer, void *);
typedef unsigned GConnectFlags;

/* Opaque GObject/Gst pointers -- we only pass them through / hand them to accessor functions. */
extern gboolean      gst_caps_is_empty(void *caps);
extern void        *gst_caps_get_structure(void *caps, unsigned index);
extern const gchar *gst_structure_get_name(void *structure);
extern const gchar *gst_plugin_feature_get_name(void *feature);

typedef gulong (*gscd_t)(gpointer, const gchar*, GCallback, gpointer, GClosureNotify, GConnectFlags);

/* GstAutoplugSelectResult: 0 = TRY, 1 = EXPOSE, 2 = SKIP. */
#define AUTOPLUG_TRY  0
#define AUTOPLUG_SKIP 2

static void shimlog(const char *m){FILE*f=fopen("/tmp/mp-shim.log","a");if(f){fputs(m,f);fclose(f);}}

static gint my_select(void *bin, void *pad, void *caps, void *factory, gpointer data)
{
	(void) bin; (void) pad; (void) data;
	const char *fn = factory ? gst_plugin_feature_get_name(factory) : NULL;
	void *s = (caps && !gst_caps_is_empty(caps)) ? gst_caps_get_structure(caps, 0) : NULL;
	const char *cn = s ? gst_structure_get_name(s) : NULL;
	int is_vpx = cn && (strstr(cn, "x-vp8") || strstr(cn, "x-vp9"));

	{ char b[200]; snprintf(b, sizeof b, "select fac=%s caps=%s\n", fn ? fn : "?", cn ? cn : "?"); shimlog(b); }

	if (is_vpx) {
		/* The SoC hardware decoder only does H.264/H.263; skip it for VP8/VP9 so decodebin plugs the
		 * software vp8dec/vp9dec instead. */
		if (fn && !strcmp(fn, "palmvideodecoder")) { shimlog("  -> SKIP hardware for VP8/VP9\n"); return AUTOPLUG_SKIP; }
		shimlog("  -> TRY software for VP8/VP9\n");
		return AUTOPLUG_TRY;
	}
	/* H.264 (hardware palmvideodecoder), audio, everything else: decodebin default. NEVER defer to the
	 * original binding -- that broke H.264 (see header). */
	return AUTOPLUG_TRY;
}

/* Force multi-threaded libvpx decode. gstvp9dec/gstvp8dec call vpx_codec_dec_init_ver with cfg=NULL,
 * so libvpx defaults to threads=1 and VP9 (heavy software decode) ran on a single core -> choppy. The
 * symbol is an interposable PLT entry in libgstvpx.so, so we override it and substitute a cfg with
 * threads = online CPUs (2 on the TouchPad's Qualcomm Snapdragon S3 / APQ8060). Only vp8/vp9 reach this. */
struct vpx_dec_cfg { unsigned int threads, w, h; };
typedef int (*vpx_dec_init_fn)(void*, void*, const struct vpx_dec_cfg*, long, int);
int vpx_codec_dec_init_ver(void *ctx, void *iface, const struct vpx_dec_cfg *cfg,
                           long flags, int ver)
{
	static vpx_dec_init_fn real = NULL;
	struct vpx_dec_cfg local;
	long n;
	unsigned int th;
	if (!real) {
		/* dlopen(RTLD_NOLOAD) returns libgstvpx's own (non-interposed) definition */
		void *h = dlopen("/usr/lib/gstreamer-0.10/libgstvpx.so", RTLD_NOLOAD | RTLD_LAZY);
		if (h) real = (vpx_dec_init_fn) dlsym(h, "vpx_codec_dec_init_ver");
		if (!real) real = (vpx_dec_init_fn) dlsym(RTLD_NEXT, "vpx_codec_dec_init_ver");
	}
	n = sysconf(_SC_NPROCESSORS_ONLN);
	th = (n > 1) ? (unsigned int) n : 1;
	if (th > 4) th = 4;
	if (!cfg) { local.threads = th; local.w = 0; local.h = 0; cfg = &local; }
	else if (cfg->threads <= 1) { local = *cfg; local.threads = th; cfg = &local; }
	{ char b[64]; snprintf(b, sizeof b, "vpx_dec_init threads=%u\n", cfg->threads); shimlog(b); }
	return real ? real(ctx, iface, cfg, flags, ver) : -1;
}

gulong g_signal_connect_data(gpointer instance, const gchar *sig, GCallback cb, gpointer data,
                             GClosureNotify destroy, GConnectFlags flags)
{
	static gscd_t real = NULL;
	if (!real) real = (gscd_t)dlsym(RTLD_NEXT, "g_signal_connect_data");
	if (sig && !strcmp(sig, "autoplug-select")) {
		/* Install our handler in place of the media server's (keep the original user_data + destroy so
		 * teardown still frees the original binding's closure). We do NOT capture or call the original
		 * binding -- my_select answers autoplug-select entirely. */
		return real(instance, sig, (GCallback)my_select, data, destroy, flags);
	}
	return real(instance, sig, cb, data, destroy, flags);
}
