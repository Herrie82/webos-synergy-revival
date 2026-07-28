// call.c — luna-service2 call service for WhatsApp calling, hosted INSIDE the
// messaging plugin (imlibpurpletransport) instead of a separate wacallm process.
//
// Ported from wacallm's svc/main.c. Differences:
//   * registers com.palm.whatsapp.call and attaches to libpurple's default
//     GMainContext (the transport already services it) — no own mainloop, mirroring
//     signal/purple-presage/src/c/call.c and telegram/tdlib-purple/call-luna.cpp.
//   * initialised once from glue/login.c (whatsapp_call_luna_init) on login.
//   * the WhatsApp engine (meowcaller) is attached to the plugin's shared whatsmeow
//     client in Go (call.go:startCalling) — C here only bridges Luna + audio.
//
// Go -> C callbacks (called from call.go):
//   gowhatsapp_call_on_state(json)      -> push to callStateQuery subscribers (mainloop-safe)
//   gowhatsapp_call_on_speaker(pcm, n)  -> received PCM -> ALSA playback
//   gowhatsapp_call_audio_active(on)    -> open/close the ALSA playback+capture path
//   gowhatsapp_call_read_mic(out, n)    -> Go PULLS mic PCM from the C ring
// C -> Go exports (from libwhatsmeow.h): gowhatsapp_go_call_dial/_answer/_hangup/_hangup_all

#include <glib.h>
#include <lunaservice.h>
#include <alsa/asoundlib.h>
#include <pthread.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "denoise.h"

#include "libwhatsmeow.h" // go-generated: gowhatsapp_go_call_dial/_answer/_hangup/_hangup_all

static LSPalmService *g_psh = NULL;
static LSHandle *g_pub = NULL;
static LSHandle *g_prv = NULL;
static GMainLoop *g_loopRef = NULL;
static int g_registered = 0;

/* ---------- minimal JSON helpers (flat CallSynergizer payloads only) ---------- */
static gboolean json_str(const char *json, const char *key, char *out, size_t outsz) {
	char pat[64];
	snprintf(pat, sizeof pat, "\"%s\"", key);
	const char *k = strstr(json, pat);
	if (!k) return FALSE;
	const char *c = strchr(k + strlen(pat), ':');
	if (!c) return FALSE;
	for (c++; *c == ' ' || *c == '\t'; c++) {}
	if (*c != '"') return FALSE;
	c++;
	size_t i = 0;
	while (*c && *c != '"' && i + 1 < outsz) {
		if (*c == '\\' && c[1]) c++;
		out[i++] = *c++;
	}
	out[i] = 0;
	return TRUE;
}
static gboolean json_true(const char *json, const char *key) {
	char pat[64];
	snprintf(pat, sizeof pat, "\"%s\"", key);
	const char *k = strstr(json, pat);
	if (!k) return FALSE;
	const char *c = strchr(k + strlen(pat), ':');
	if (!c) return FALSE;
	for (c++; *c == ' ' || *c == '\t'; c++) {}
	return strncmp(c, "true", 4) == 0;
}

static void reply(LSHandle *sh, LSMessage *msg, const char *payload) {
	LSError e;
	LSErrorInit(&e);
	if (!LSMessageReply(sh, msg, payload, &e)) {
		fprintf(stderr, "wa-call: LSMessageReply failed: %s\n", e.message);
		LSErrorFree(&e);
	}
}

/* ---------- Go -> C: push callState to subscribers on the mainloop ---------- */
static gboolean push_callstate(gpointer data) {
	char *json = (char *)data;
	LSError e;
	LSErrorInit(&e);
	if (g_pub) LSSubscriptionReply(g_pub, "callState", json, &e);
	if (g_prv) LSSubscriptionReply(g_prv, "callState", json, &e);
	g_free(json);
	return G_SOURCE_REMOVE;
}
void gowhatsapp_call_on_state(const char *json) {
	// copy now (Go frees its buffer on return) and dispatch onto the mainloop
	g_idle_add(push_callstate, g_strdup(json));
}

/* ---------- audio bridge: ALSA voip/voipsource (routes through PulseAudio) ---------- */
// meowcaller PCM is float32, 16 kHz, mono, 960 samples/frame. "voip"/"voipsource"
// (not "default") -> PA pvoip/pvoipsource, which module-palm-policy routes under the
// phone scenario, so we coexist with audiod/PA (no hw conflict).
#define WA_RATE 16000
#define WA_FRAME 960
#define MIC_RING 16000 /* ~1s of int16 mono */
static snd_pcm_t *g_play = NULL; // peer -> speaker (written from the sink callback)
static snd_pcm_t *g_cap = NULL;  // mic (read by the capture thread into the ring)
static pthread_t g_cap_thread;
static volatile int g_audio_on = 0;
// Mic ring buffer: the capture thread (pure C) fills it; Go PULLS via
// gowhatsapp_call_read_mic (Go->C, always safe). No C-thread->Go calls.
static short g_mic[MIC_RING];
static int g_mic_head = 0, g_mic_tail = 0; // tail=write, head=read
static pthread_mutex_t g_mic_mx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_mic_cv = PTHREAD_COND_INITIALIZER;

static int mic_avail(void) {
	int a = g_mic_tail - g_mic_head;
	if (a < 0) a += MIC_RING;
	return a;
}

static snd_pcm_t *pcm_open(const char *dev, snd_pcm_stream_t dir) {
	snd_pcm_t *h = NULL;
	if (snd_pcm_open(&h, dev, dir, 0) < 0) return NULL;
	// S16_LE, mono, 16k, soft-resample on, ~120ms latency
	if (snd_pcm_set_params(h, SND_PCM_FORMAT_S16_LE, SND_PCM_ACCESS_RW_INTERLEAVED,
	                       1, WA_RATE, 1, 120000) < 0) {
		snd_pcm_close(h);
		return NULL;
	}
	return h;
}

// Capture thread: pure C. Opens both ALSA devices (off the mainloop — snd_pcm_open
// on the pulse plugin can block) then reads mic -> ring buffer. Never calls into Go.
static void *audio_thread(void *arg) {
	(void)arg;
	g_play = pcm_open("voip", SND_PCM_STREAM_PLAYBACK);
	g_cap = pcm_open("voipsource", SND_PCM_STREAM_CAPTURE);
	fprintf(stderr, "wa-call: audio %s / %s\n",
	        g_play ? "playback-ok" : "playback-FAIL",
	        g_cap ? "capture-ok" : "capture-FAIL");
	// WebRTC noise-suppression on the outbound mic (the webOS voip capture path applies no audiod DSP,
	// so the raw analog-mic frames carry heavy background noise). Denoise in place before the ring.
	wa_ns_start(WA_RATE);
	short buf[WA_FRAME];
	while (g_audio_on && g_cap) {
		snd_pcm_sframes_t r = snd_pcm_readi(g_cap, buf, WA_FRAME);
		if (r < 0) {
			snd_pcm_recover(g_cap, (int)r, 1);
			continue;
		}
		wa_ns_process(buf, (int)r);
		pthread_mutex_lock(&g_mic_mx);
		for (int i = 0; i < r; i++) {
			int nt = (g_mic_tail + 1) % MIC_RING;
			if (nt == g_mic_head) g_mic_head = (g_mic_head + 1) % MIC_RING; // drop oldest
			g_mic[g_mic_tail] = buf[i];
			g_mic_tail = nt;
		}
		pthread_cond_signal(&g_mic_cv);
		pthread_mutex_unlock(&g_mic_mx);
	}
	wa_ns_stop();
	return NULL;
}

// gowhatsapp_call_read_mic — called from Go (meowcaller's mic source, a Go thread) to
// PULL n float32 samples. Blocks until n are available or audio stops (then silence).
int gowhatsapp_call_read_mic(float *out, int n) {
	pthread_mutex_lock(&g_mic_mx);
	while (g_audio_on && mic_avail() < n)
		pthread_cond_wait(&g_mic_cv, &g_mic_mx);
	int i = 0;
	while (i < n && g_mic_head != g_mic_tail) {
		out[i++] = (float)g_mic[g_mic_head] / 32768.0f;
		g_mic_head = (g_mic_head + 1) % MIC_RING;
	}
	pthread_mutex_unlock(&g_mic_mx);
	for (; i < n; i++) out[i] = 0.0f; // pad with silence if stopping
	return n;
}

void gowhatsapp_call_on_speaker(const float *frame, int n) {
	snd_pcm_t *h = g_play;
	if (!h || n <= 0) return;
	short buf[2048];
	if (n > 2048) n = 2048;
	for (int i = 0; i < n; i++) {
		float f = frame[i];
		if (f > 1.0f) f = 1.0f;
		if (f < -1.0f) f = -1.0f;
		buf[i] = (short)(f * 32767.0f);
	}
	snd_pcm_sframes_t w = snd_pcm_writei(h, buf, n);
	if (w < 0) snd_pcm_recover(h, (int)w, 1);
}

// Tell audiod there's an active voip call so it enables the phone scenario.
static bool audiod_reply(LSHandle *sh, LSMessage *m, void *ctx) {
	(void)sh; (void)m; (void)ctx;
	return true;
}
static void audiod_send(const char *uri, const char *payload) {
	LSError e;
	LSErrorInit(&e);
	LSMessageToken t;
	if (g_prv && !LSCallOneReply(g_prv, uri, payload, audiod_reply, NULL, &t, &e)) {
		fprintf(stderr, "wa-call: audiod %s failed: %s\n", uri, e.message);
		LSErrorFree(&e);
	}
}
static gboolean audiod_status_idle(gpointer d) {
	int active = GPOINTER_TO_INT(d);
	if (active) {
		audiod_send("palm://com.palm.audio/phone/CallStatusUpdate",
		            "{\"lines\":[{\"state\":\"active\",\"calls\":[{\"id\":1,\"address\":\"whatsapp\",\"origin\":\"outgoing\",\"video\":false,\"transport\":\"com.palm.whatsapp\"}]}]}");
		// The TouchPad has NO earpiece/receiver — default call audio to the LOUDSPEAKER
		// (phone_back_speaker). audiod auto-switches to headset / Bluetooth when present.
		audiod_send("palm://com.palm.audio/phone/setCurrentScenario",
		            "{\"scenario\":\"phone_back_speaker\"}");
		fprintf(stderr, "wa-call: audiod voip call ON (loudspeaker)\n");
	} else {
		audiod_send("palm://com.palm.audio/phone/CallStatusUpdate", "{\"lines\":[]}");
		fprintf(stderr, "wa-call: audiod voip call OFF\n");
	}
	return G_SOURCE_REMOVE;
}

// Called from Go (a goroutine thread) when a call becomes active (1) / ends (0).
// MUST NOT BLOCK — it just starts/stops the audio thread; the ALSA open (which can
// block on the pulse plugin) happens inside that thread. The audiod call is dispatched
// onto the mainloop (LSCall isn't safe off the mainloop thread).
void gowhatsapp_call_audio_active(int on) {
	if (on && !g_audio_on) {
		g_audio_on = 1;
		g_idle_add(audiod_status_idle, GINT_TO_POINTER(1));
		pthread_create(&g_cap_thread, NULL, audio_thread, NULL);
	} else if (!on && g_audio_on) {
		g_idle_add(audiod_status_idle, GINT_TO_POINTER(0));
		g_audio_on = 0;
		pthread_mutex_lock(&g_mic_mx);
		pthread_cond_broadcast(&g_mic_cv); // wake any blocked read_mic
		pthread_mutex_unlock(&g_mic_mx);
		pthread_join(g_cap_thread, NULL); // returns within ~one 60ms read
		if (g_cap) {
			snd_pcm_close(g_cap);
			g_cap = NULL;
		}
		snd_pcm_t *p = g_play;
		g_play = NULL;
		if (p) snd_pcm_close(p);
	}
}

/* ---------- Luna method handlers ---------- */
static bool m_dial(LSHandle *sh, LSMessage *msg, void *ctx) {
	(void)ctx;
	const char *p = LSMessageGetPayload(msg);
	char addr[160] = "";
	if (!p || !json_str(p, "address", addr, sizeof addr)) {
		reply(sh, msg, "{\"returnValue\":false,\"errorText\":\"missing address\"}");
		return true;
	}
	int video = json_true(p, "video") ? 1 : 0;
	char *id = gowhatsapp_go_call_dial(addr, video); // Go-malloc'd C string
	char out[256];
	snprintf(out, sizeof out, "{\"returnValue\":%s,\"id\":\"%s\"}",
	         (id && id[0]) ? "true" : "false", id ? id : "");
	if (id) free(id);
	reply(sh, msg, out);
	return true;
}
static bool m_answer(LSHandle *sh, LSMessage *msg, void *ctx) {
	(void)ctx;
	const char *p = LSMessageGetPayload(msg);
	char id[128] = "";
	if (!p || !json_str(p, "id", id, sizeof id)) {
		reply(sh, msg, "{\"returnValue\":false,\"errorText\":\"missing id\"}");
		return true;
	}
	int video = json_true(p, "video") ? 1 : 0;
	int rc = gowhatsapp_go_call_answer(id, video);
	reply(sh, msg, rc == 0 ? "{\"returnValue\":true}" : "{\"returnValue\":false}");
	return true;
}
static bool m_disconnect(LSHandle *sh, LSMessage *msg, void *ctx) {
	(void)ctx;
	const char *p = LSMessageGetPayload(msg);
	char id[128] = "";
	if (p) json_str(p, "id", id, sizeof id); // may stay "" (numeric/missing) -> hangup all
	fprintf(stderr, "wa-call: disconnect id='%s' payload=%s\n", id, p ? p : "");
	gowhatsapp_go_call_hangup(id); // empty/unmatched id -> hang up all live calls
	reply(sh, msg, "{\"returnValue\":true}");
	return true;
}
static bool m_callstate(LSHandle *sh, LSMessage *msg, void *ctx) {
	(void)ctx;
	LSError e;
	LSErrorInit(&e);
	if (!LSSubscriptionAdd(sh, "callState", msg, &e)) {
		fprintf(stderr, "wa-call: LSSubscriptionAdd failed: %s\n", e.message);
		LSErrorFree(&e);
	}
	reply(sh, msg, "{\"returnValue\":true,\"subscribed\":true}");
	return true;
}
static bool m_hangupall(LSHandle *sh, LSMessage *msg, void *ctx) {
	(void)ctx;
	gowhatsapp_go_call_hangup_all();
	reply(sh, msg, "{\"returnValue\":true}");
	return true;
}
// Accept-and-ack stubs for verbs the dialer may send (wire up as needed).
static bool m_ok(LSHandle *sh, LSMessage *msg, void *ctx) {
	(void)ctx;
	reply(sh, msg, "{\"returnValue\":true}");
	return true;
}

static LSMethod methods[] = {
	{"dial", m_dial},
	{"answer", m_answer},
	{"disconnect", m_disconnect},
	{"hangupAll", m_hangupall},
	{"hangupAllActive", m_hangupall},
	{"hangupAllHeld", m_hangupall},
	{"hangupMMI", m_hangupall},
	{"callStateQuery", m_callstate},
	{"hold", m_ok},
	{"swap", m_ok},
	{"merge", m_ok},
	{"extract", m_ok},
	{"dtmf", m_ok},
	{"dtmfEnd", m_ok},
	{"changeMedia", m_ok},
	{NULL, NULL},
};

// whatsapp_call_luna_init — register com.palm.whatsapp.call on libpurple's default
// GMainContext. Idempotent: only the first WhatsApp login registers; the service then
// lives for the process lifetime (mirrors signal/purple-presage call.c).
void whatsapp_call_luna_init(void) {
	if (g_registered) return;
	LSError e;
	LSErrorInit(&e);

	if (!LSRegisterPalmService("com.palm.whatsapp.call", &g_psh, &e)) {
		fprintf(stderr, "wa-call: LSRegisterPalmService: %s\n", e.message);
		LSErrorFree(&e);
		return;
	}
	g_pub = LSPalmServiceGetPublicConnection(g_psh);
	g_prv = LSPalmServiceGetPrivateConnection(g_psh);

	if (!LSPalmServiceRegisterCategory(g_psh, "/", methods, methods, NULL, NULL, &e)) {
		fprintf(stderr, "wa-call: RegisterCategory: %s\n", e.message);
		LSErrorFree(&e);
		return;
	}
	// Attach to the GMainContext libpurple already services (no separate loop/thread).
	g_loopRef = g_main_loop_new(g_main_context_default(), FALSE);
	if (!LSGmainAttachPalmService(g_psh, g_loopRef, &e)) {
		fprintf(stderr, "wa-call: GmainAttach: %s\n", e.message);
		LSErrorFree(&e);
		return;
	}
	g_registered = 1;
	fprintf(stderr, "wa-call: com.palm.whatsapp.call up (in-plugin)\n");
}
