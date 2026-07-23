/* LD_PRELOAD shim for webOS media-pipeline.real. The media server's PlaybinPipeline gates decodebin2
 * with custom autoplug-select/autoplug-continue handlers that don't handle our backported software
 * codecs (vp8dec/vp9dec/etc): VP9 ends up mis-routed to the hardware palmvideodecoder (H.264/H.263
 * only), which chokes (chain error -2) -> the videoplayer just spins.
 *
 * We replace both handlers with decodebin2's OWN DEFAULT policy (identical to plain `gst-launch
 * playbin2`, which decodes our VP9 sample fine):
 *   autoplug-select  -> TRY (0)   : try every candidate factory by rank. Hardware palmvideodecoder
 *                                    (rank primary, x-h264) still wins for H.264; x-vp9 has only
 *                                    vp9dec as a candidate, so it gets picked.
 *   autoplug-continue -> TRUE      : keep plugging toward a decoded/raw pad (the pipeline's normal
 *                                    raw-sink path) instead of exposing x-vp9 undecoded.
 * We never call the pipeline's original C++ handler (that SIGABRTs on a calling-convention mismatch),
 * so there is no crash surface. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <string.h>
#include <glib-object.h>
#include <gst/gst.h>

typedef gulong (*gscd_t)(gpointer, const gchar*, GCallback, gpointer, GClosureNotify, GConnectFlags);
static gint     my_select(GstElement *b, GstPad *p, GstCaps *c, GstElementFactory *f, gpointer d){ return 0; }   /* TRY */
static gboolean my_continue(GstElement *b, GstPad *p, GstCaps *c, gpointer d){ return TRUE; }                     /* keep decoding */

gulong g_signal_connect_data(gpointer instance, const gchar *sig, GCallback cb, gpointer data,
                             GClosureNotify destroy, GConnectFlags flags){
	static gscd_t real=NULL;
	if(!real) real=(gscd_t)dlsym(RTLD_NEXT,"g_signal_connect_data");
	if(sig && !strcmp(sig,"autoplug-select"))   return real(instance,sig,(GCallback)my_select,NULL,NULL,flags);
	if(sig && !strcmp(sig,"autoplug-continue")) return real(instance,sig,(GCallback)my_continue,NULL,NULL,flags);
	return real(instance,sig,cb,data,destroy,flags);
}
