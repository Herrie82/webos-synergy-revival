/* LD_PRELOAD shim for webOS media-pipeline.real (SURGICAL, Ghidra-decompile-informed).
 *
 * The media server's decodebin autoplug handlers (media::pipeline::gst::element::DecodeBin):
 *   autoplugContinue()      -> returns TRUE unconditionally; its *binding* has a vtable side effect,
 *                              so we must NOT touch autoplug-continue (replacing it -> pipeline crash).
 *   autoplugSelectBinding() -> dispatches a boost::signals2 signal held at (DecodeBin*)+0x40 and
 *                              __assert_fail("px != 0")s if that object is null -> so it must be called
 *                              with the REAL DecodeBin user_data, never NULL (that was the old SIGABRT).
 *
 * So we intercept ONLY autoplug-select, register our wrapper with the ORIGINAL user_data, force
 * GST_AUTOPLUG_SELECT_TRY(0) just for our software vp8dec/vp9dec on x-vp8/x-vp9 caps, and defer to the
 * original binding (preserving its policy + side effects) for everything else. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <string.h>
#include <glib-object.h>
#include <gst/gst.h>
#include <stdio.h>
#include <unistd.h>

typedef gulong (*gscd_t)(gpointer, const gchar*, GCallback, gpointer, GClosureNotify, GConnectFlags);
typedef gint   (*select_fn)(GstElement*, GstPad*, GstCaps*, GstElementFactory*, gpointer);

static select_fn g_orig_select = NULL;

static void shimlog(const char*m){FILE*f=fopen("/tmp/mp-shim.log","a");if(f){fputs(m,f);fclose(f);}}
static gint my_select(GstElement *bin, GstPad *pad, GstCaps *caps, GstElementFactory *factory, gpointer data)
{
	{char b[200];const GstStructure*ss=(caps&&!gst_caps_is_empty(caps))?gst_caps_get_structure(caps,0):NULL;snprintf(b,sizeof b,"select fac=%s caps=%s\n",factory?gst_plugin_feature_get_name((GstPluginFeature*)factory):"?",ss?gst_structure_get_name(ss):"?");shimlog(b);}
	const char *fn = factory ? gst_plugin_feature_get_name((GstPluginFeature*)factory) : NULL;
	if (fn && (!strcmp(fn, "vp9dec") || !strcmp(fn, "vp8dec"))) {
		const GstStructure *s = (caps && !gst_caps_is_empty(caps)) ? gst_caps_get_structure(caps, 0) : NULL;
		const char *cn = s ? gst_structure_get_name(s) : NULL;
		if (cn && (strstr(cn, "x-vp9") || strstr(cn, "x-vp8")))
			shimlog("  -> FORCED vp8/vp9dec\n");return 0;
	}
	if (g_orig_select) return g_orig_select(bin, pad, caps, factory, data); /* real data => no px!=0 assert */
	return 0;
}

/* Force multi-threaded libvpx decode. gstvp9dec/gstvp8dec call vpx_codec_dec_init_ver
 * with cfg=NULL, so libvpx defaults to threads=1 and VP9 (heavy software decode) ran on
 * a single core -> choppy. The symbol is an interposable PLT entry in libgstvpx.so, so we
 * override it and substitute a cfg with threads = online CPUs (2 on the TouchPad's OMAP4),
 * spreading tile/loopfilter work across both cores. Only vp8/vp9 decode reaches this. */
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
		g_orig_select = (select_fn)cb;
		return real(instance, sig, (GCallback)my_select, data, destroy, flags); /* keep original data */
	}
	return real(instance, sig, cb, data, destroy, flags);
}
