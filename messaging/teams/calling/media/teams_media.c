/*
 * teams_media.c - Microsoft Teams (personal/TFL) 1:1 call MEDIA ENGINE for webOS, answerer side.
 *
 * Forked from the on-device-proven Signal engine (signal_media.c). Teams consumer calling turns out
 * to offer EXACTLY what that engine already does: AEAD_AES_256_GCM SRTP + Opus (PT 102) + ICE
 * (libnice). The ONLY real difference is keying: Teams uses SDES (the SRTP master key is carried
 * inline in the SDP `a=crypto` line), NOT an X25519 DH. So instead of deriving keys, we:
 *   - take the peer's RX master (base64 from the offer's `a=crypto:4 AEAD_AES_256_GCM inline:...`),
 *   - generate our own random TX master and hand it back (base64) for the SDP answer's a=crypto.
 * We also generate our own ICE ufrag/pwd (libnice) and emit them + our candidates for the answer.
 *
 *   RX: nicesrc -> srtpdec(peer master via request-key) -> rtpopusdepay -> opusdec -> alsasink device=voip
 *   TX: alsasrc device=voipsource -> opusenc -> rtpopuspay(pt) -> srtpenc(our master) -> nicesink
 *
 * IPC (line protocol over stdin/stdout, driven by teams_calling.c):
 *   in : START <rx_master_b64> <remote_ufrag> <remote_pwd> <pt>
 *        RELAY turn <ip> <port> <user> <pass> <udp|tcp|tls>   (optional; MS-TURN relay)
 *        RELAY stun <host> <port>                             (optional)
 *        RCAND <candidate:... sdp line>                       (a remote ICE candidate; repeatable)
 *        STOP
 *   out: UFRAG <our_ufrag>
 *        PWD <our_pwd>
 *        TXKEY <tx_master_b64>                                (our a=crypto inline key for the answer)
 *        CAND <candidate:... sdp line>                        (our local ICE candidate)
 *        AUDIOD <0|1>
 *        READY | ERR <msg>
 *
 * Standalone build also supports --loopback (SRTP-GCM+RTP+Opus round-trip, no ICE/ALSA).
 */

#include <gst/gst.h>
#include <nice/agent.h>
#include <glib.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>

/* Opus RTP: 48 kHz. PT is dictated by the peer's offer (Teams uses 102); parsed from START. */
#define TM_OPUS_CLOCKRATE 48000
#define TM_OPUS_CHANNELS  1
#define TM_DEFAULT_PT     102

#define SRTP_CIPHER_GCM256 "aes-256-gcm"
#define SRTP_AUTH_NULL     "null"          /* GCM is AEAD -> no separate auth transform */
#define TM_GCM_MASTER_SIZE 44              /* AEAD_AES_256_GCM: 32-byte key || 12-byte salt */

typedef struct {
    GMainContext *ctx;
    GMainLoop    *loop;
    GThread      *thread;

    NiceAgent    *agent;
    guint         stream_id;
    guint         component;   /* 1 = RTP (rtcp-mux) */

    GstElement   *pipeline;

    GstBuffer    *rx_master;    /* peer's SRTP master (decrypt RX), 44B */
    GstBuffer    *tx_master;    /* our SRTP master (encrypt TX), 44B */
    int           pt;           /* opus payload type from the offer */

    void (*cand_cb)(const char *sdp);
    void (*audiod_cb)(int active);

    gboolean      audiod_on;
    gboolean      running;
} TeamsMedia;

static TeamsMedia g_tm;
static gsize      g_inited = 0;

/* STUN/TURN relays (set via RELAY before START) */
#define TM_MAX_TURN 8
typedef struct { char host[64]; int port; char user[128]; char pass[256]; NiceRelayType type; } TmTurn;
static char   g_stun_host[64];
static int    g_stun_port;
static TmTurn g_turn[TM_MAX_TURN];
static int    g_n_turn;

static void tm_trace(const char *msg)
{
    FILE *f = fopen("/media/internal/teams-media.log", "a");
    if (f) { fputs(msg, f); fputc('\n', f); fclose(f); }
}

/* ------------------------------------------------------------------ helpers ------------------- */

static GstBuffer *master_buffer_from_bytes(const guchar *data, gsize len)
{
    GstBuffer *buf = gst_buffer_new_and_alloc(TM_GCM_MASTER_SIZE);
    GstMapInfo map;
    if (!gst_buffer_map(buf, &map, GST_MAP_WRITE)) { gst_buffer_unref(buf); return NULL; }
    memset(map.data, 0, TM_GCM_MASTER_SIZE);
    memcpy(map.data, data, len < TM_GCM_MASTER_SIZE ? len : TM_GCM_MASTER_SIZE);
    gst_buffer_unmap(buf, &map);
    return buf;
}

static GstElement *mk(const char *factory, const char *name)
{
    GstElement *e = gst_element_factory_make(factory, name);
    if (!e) g_printerr("teams_media: missing GStreamer element '%s'\n", factory);
    return e;
}

static void configure_srtpenc(GstElement *enc, GstBuffer *master)
{
    g_object_set(enc, "key", master, NULL);
    gst_util_set_object_arg(G_OBJECT(enc), "rtp-cipher",  SRTP_CIPHER_GCM256);
    gst_util_set_object_arg(G_OBJECT(enc), "rtp-auth",    SRTP_AUTH_NULL);
    gst_util_set_object_arg(G_OBJECT(enc), "rtcp-cipher", SRTP_CIPHER_GCM256);
    gst_util_set_object_arg(G_OBJECT(enc), "rtcp-auth",   SRTP_AUTH_NULL);
}

static GstCaps *on_srtpdec_request_key(GstElement *dec, guint ssrc, gpointer user)
{
    (void)dec;
    TeamsMedia *tm = (TeamsMedia *)user;
    g_message("teams_media: srtpdec request-key ssrc %u (inbound SRTP arriving)", ssrc);
    if (!tm->rx_master) return NULL;
    GstCaps *caps = gst_caps_new_simple("application/x-srtp",
                                        "srtp-cipher",  G_TYPE_STRING, SRTP_CIPHER_GCM256,
                                        "srtp-auth",    G_TYPE_STRING, SRTP_AUTH_NULL,
                                        "srtcp-cipher", G_TYPE_STRING, SRTP_CIPHER_GCM256,
                                        "srtcp-auth",   G_TYPE_STRING, SRTP_AUTH_NULL, NULL);
    gst_caps_set_simple(caps, "srtp-key", GST_TYPE_BUFFER, gst_buffer_ref(tm->rx_master), NULL);
    return caps;
}

static GstCaps *opus_rtp_caps(int pt)
{
    return gst_caps_new_simple("application/x-rtp",
                               "media",         G_TYPE_STRING, "audio",
                               "clock-rate",    G_TYPE_INT,    TM_OPUS_CLOCKRATE,
                               "encoding-name", G_TYPE_STRING, "OPUS",
                               "payload",       G_TYPE_INT,    pt, NULL);
}

/* ------------------------------------------------------------------ bus ------------------------ */

static gboolean on_bus(GstBus *bus, GstMessage *msg, gpointer user)
{
    (void)bus;
    TeamsMedia *tm = (TeamsMedia *)user;
    switch (GST_MESSAGE_TYPE(msg)) {
        case GST_MESSAGE_ERROR: {
            GError *err = NULL; gchar *dbg = NULL;
            gst_message_parse_error(msg, &err, &dbg);
            g_printerr("teams_media: pipeline ERROR from %s: %s (%s)\n",
                       GST_OBJECT_NAME(msg->src), err ? err->message : "?", dbg ? dbg : "");
            { char t[512]; g_snprintf(t, sizeof t, "PIPELINE ERROR %s: %s", GST_OBJECT_NAME(msg->src), err ? err->message : "?"); tm_trace(t); }
            if (err) g_error_free(err);
            g_free(dbg);
            break;
        }
        case GST_MESSAGE_STATE_CHANGED:
            if (GST_MESSAGE_SRC(msg) == GST_OBJECT(tm->pipeline)) {
                GstState o, n; gst_message_parse_state_changed(msg, &o, &n, NULL);
                if (n == GST_STATE_PLAYING && !tm->audiod_on) {
                    g_message("teams_media: pipeline PLAYING");
                    tm_trace("pipeline PLAYING");
                    tm->audiod_on = TRUE;
                    if (tm->audiod_cb) tm->audiod_cb(1);
                }
            }
            break;
        default: break;
    }
    return TRUE;
}

/* ------------------------------------------------------------------ ICE ------------------------ */

static void on_nice_candidate(NiceAgent *agent, NiceCandidate *cand, gpointer user)
{
    TeamsMedia *tm = (TeamsMedia *)user;
    gchar *sdp = nice_agent_generate_local_candidate_sdp(agent, cand);
    if (sdp) {
        const char *bare = (strncmp(sdp, "a=", 2) == 0) ? sdp + 2 : sdp;
        g_message("teams_media: LOCAL candidate -> %s", bare);
        if (tm->cand_cb) tm->cand_cb(bare);
        g_free(sdp);
    }
}

static void on_nice_gathering_done(NiceAgent *agent, guint stream_id, gpointer user)
{ (void)agent;(void)stream_id;(void)user; g_message("teams_media: ICE gathering done"); tm_trace("ICE gathering done"); }

static void on_nice_state(NiceAgent *agent, guint stream_id, guint cid, guint state, gpointer user)
{
    (void)user;
    g_message("teams_media: ICE state -> %s", nice_component_state_to_string(state));
    { char t[96]; g_snprintf(t, sizeof t, "ICE state %s", nice_component_state_to_string(state)); tm_trace(t); }
    if (state == NICE_COMPONENT_STATE_CONNECTED || state == NICE_COMPONENT_STATE_READY) {
        NiceCandidate *lc = NULL, *rc = NULL;
        if (nice_agent_get_selected_pair(agent, stream_id, cid, &lc, &rc) && lc && rc) {
            gchar *ls = nice_agent_generate_local_candidate_sdp(agent, lc);
            gchar *rs = nice_agent_generate_local_candidate_sdp(agent, rc);
            g_message("teams_media: ICE SELECTED local[%s] remote[%s]", ls?ls:"?", rs?rs:"?");
            g_free(ls); g_free(rs);
        }
    }
}

/* Build the agent (answerer = controlled), set remote creds, gather. Our local creds are generated
 * by libnice and read back by the caller of this fn (to emit UFRAG/PWD). */
static gboolean build_ice(TeamsMedia *tm, const char *remote_ufrag, const char *remote_pwd)
{
    tm_trace("build_ice enter");
    /* NICE_COMPATIBILITY_RFC5245 = standard ICE. Teams' MS-ICE is close enough for host/srflx/relay
     * pairing in practice; if MS-specific quirks block it we may need MS-TURN via RELAY. */
    tm->agent = nice_agent_new(tm->ctx, NICE_COMPATIBILITY_RFC5245);
    if (!tm->agent) { g_printerr("teams_media: nice_agent_new failed\n"); return FALSE; }
    g_object_set(tm->agent, "controlling-mode", FALSE, NULL);   /* answerer = controlled */

    if (g_stun_port)
        g_object_set(tm->agent, "stun-server", g_stun_host, "stun-server-port", (guint)g_stun_port, NULL);

    tm->component = 1;
    tm->stream_id = nice_agent_add_stream(tm->agent, 1);
    if (!tm->stream_id) { g_printerr("teams_media: add_stream failed\n"); return FALSE; }

    for (int i = 0; i < g_n_turn; i++) {
        TmTurn *t = &g_turn[i];
        if (nice_agent_set_relay_info(tm->agent, tm->stream_id, tm->component,
                                      t->host, (guint)t->port, t->user, t->pass, t->type))
            g_message("teams_media: TURN relay %s:%d type=%d", t->host, t->port, (int)t->type);
        else
            g_printerr("teams_media: set_relay_info failed %s:%d\n", t->host, t->port);
    }

    if (remote_ufrag && remote_pwd)
        nice_agent_set_remote_credentials(tm->agent, tm->stream_id, remote_ufrag, remote_pwd);

    g_signal_connect(tm->agent, "new-candidate-full",       G_CALLBACK(on_nice_candidate),      tm);
    g_signal_connect(tm->agent, "candidate-gathering-done", G_CALLBACK(on_nice_gathering_done), tm);
    g_signal_connect(tm->agent, "component-state-changed",  G_CALLBACK(on_nice_state),          tm);

    if (!nice_agent_gather_candidates(tm->agent, tm->stream_id)) {
        g_printerr("teams_media: gather_candidates failed\n"); return FALSE;
    }
    return TRUE;
}

/* ------------------------------------------------------------------ pipeline ------------------- */

static gboolean build_pipeline(TeamsMedia *tm)
{
    tm->pipeline = gst_pipeline_new("teams-call");

    GstElement *nsrc  = mk("nicesrc",      "rx-nicesrc");
    GstElement *rxcap = mk("capsfilter",   "rx-srtpcaps");
    GstElement *sdec  = mk("srtpdec",      "rx-srtpdec");
    GstElement *rxrtp = mk("capsfilter",   "rx-rtpcaps");
    GstElement *depay = mk("rtpopusdepay", "rx-depay");
    GstElement *odec  = mk("opusdec",      "rx-opusdec");
    GstElement *aconv = mk("audioconvert", "rx-aconv");
    GstElement *asink = mk("alsasink",     "rx-alsasink");

    GstElement *asrc  = mk("alsasrc",      "tx-alsasrc");
    GstElement *tconv = mk("audioconvert", "tx-aconv");
    GstElement *tres  = mk("audioresample","tx-ares");
    GstElement *tcap  = mk("capsfilter",   "tx-rawcaps");
    GstElement *oenc  = mk("opusenc",      "tx-opusenc");
    GstElement *pay   = mk("rtpopuspay",   "tx-pay");
    GstElement *senc  = mk("srtpenc",      "tx-srtpenc");
    GstElement *nsink = mk("nicesink",     "tx-nicesink");

    if (!nsrc||!rxcap||!sdec||!rxrtp||!depay||!odec||!aconv||!asink||
        !asrc||!tconv||!tres||!tcap||!oenc||!pay||!senc||!nsink) {
        if (tm->pipeline) { gst_object_unref(tm->pipeline); tm->pipeline = NULL; } return FALSE;
    }

    g_object_set(nsrc,  "agent", tm->agent, "stream", tm->stream_id, "component", tm->component, NULL);
    g_object_set(nsink, "agent", tm->agent, "stream", tm->stream_id, "component", tm->component, NULL);

    { GstCaps *c = gst_caps_new_empty_simple("application/x-srtp"); g_object_set(rxcap, "caps", c, NULL); gst_caps_unref(c); }
    g_signal_connect(sdec, "request-key", G_CALLBACK(on_srtpdec_request_key), tm);
    { GstCaps *c = opus_rtp_caps(tm->pt); g_object_set(rxrtp, "caps", c, NULL); gst_caps_unref(c); }
    g_object_set(asink, "device", "voip", "sync", FALSE, NULL);

    { GstCaps *c = gst_caps_new_simple("audio/x-raw", "format", G_TYPE_STRING, "S16LE",
        "rate", G_TYPE_INT, TM_OPUS_CLOCKRATE, "channels", G_TYPE_INT, TM_OPUS_CHANNELS, NULL);
      g_object_set(tcap, "caps", c, NULL); gst_caps_unref(c); }
    g_object_set(asrc, "device", "voipsource", NULL);
    g_object_set(pay,  "pt", tm->pt, NULL);
    configure_srtpenc(senc, tm->tx_master);

    gst_bin_add_many(GST_BIN(tm->pipeline),
        nsrc, rxcap, sdec, rxrtp, depay, odec, aconv, asink,
        asrc, tconv, tres, tcap, oenc, pay, senc, nsink, NULL);

    if (!gst_element_link_many(nsrc, rxcap, sdec, rxrtp, depay, odec, aconv, asink, NULL)) {
        g_printerr("teams_media: RX link failed\n"); return FALSE; }
    if (!gst_element_link_many(asrc, tconv, tres, tcap, oenc, pay, senc, nsink, NULL)) {
        g_printerr("teams_media: TX link failed\n"); return FALSE; }

    GstBus *bus = gst_pipeline_get_bus(GST_PIPELINE(tm->pipeline));
    GSource *src = gst_bus_create_watch(bus);
    g_source_set_callback(src, (GSourceFunc)on_bus, tm, NULL);
    g_source_attach(src, tm->ctx);
    g_source_unref(src);
    gst_object_unref(bus);
    return TRUE;
}

static gpointer media_thread(gpointer data)
{
    TeamsMedia *tm = (TeamsMedia *)data;
    g_main_context_push_thread_default(tm->ctx);
    g_main_loop_run(tm->loop);
    g_main_context_pop_thread_default(tm->ctx);
    return NULL;
}

static void tm_init(void)
{
    if (g_once_init_enter(&g_inited)) { gst_init(NULL, NULL); g_once_init_leave(&g_inited, 1); }
}

/* Start the engine. rx_master_b64 = peer's SRTP key from the offer's a=crypto. Generates our TX key
 * (returned via *out_txkey_b64, caller frees) and uses libnice-generated local creds (returned via
 * *out_ufrag/*out_pwd, caller frees). */
static int tm_start(const char *rx_master_b64, const char *remote_ufrag, const char *remote_pwd, int pt,
                    void (*cand_cb)(const char*), void (*audiod_cb)(int),
                    gchar **out_ufrag, gchar **out_pwd, gchar **out_txkey_b64)
{
    tm_init();
    memset(&g_tm, 0, sizeof g_tm);
    g_tm.cand_cb = cand_cb; g_tm.audiod_cb = audiod_cb;
    g_tm.pt = pt > 0 ? pt : TM_DEFAULT_PT;

    /* RX master from the offer */
    gsize rxlen = 0;
    guchar *rxk = g_base64_decode(rx_master_b64, &rxlen);
    if (!rxk || rxlen < 32) { g_free(rxk); g_printerr("teams_media: bad rx master\n"); return -1; }
    g_tm.rx_master = master_buffer_from_bytes(rxk, rxlen);
    g_free(rxk);

    /* TX master: 44 random bytes (32 key + 12 salt), emitted as base64 for the answer's a=crypto */
    guchar txk[TM_GCM_MASTER_SIZE];
    for (int i = 0; i < TM_GCM_MASTER_SIZE; i++) txk[i] = (guchar)(g_random_int() & 0xff);
    g_tm.tx_master = master_buffer_from_bytes(txk, TM_GCM_MASTER_SIZE);
    if (out_txkey_b64) *out_txkey_b64 = g_base64_encode(txk, TM_GCM_MASTER_SIZE);

    g_tm.ctx  = g_main_context_new();
    g_tm.loop = g_main_loop_new(g_tm.ctx, FALSE);

    if (!build_ice(&g_tm, remote_ufrag, remote_pwd)) return -1;

    /* read back libnice-generated local ICE credentials for the answer */
    { gchar *uf = NULL, *pw = NULL;
      nice_agent_get_local_credentials(g_tm.agent, g_tm.stream_id, &uf, &pw);
      if (out_ufrag) *out_ufrag = uf; else g_free(uf);
      if (out_pwd)   *out_pwd   = pw; else g_free(pw); }

    if (!build_pipeline(&g_tm)) return -1;
    if (gst_element_set_state(g_tm.pipeline, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE) {
        g_printerr("teams_media: set PLAYING failed\n"); return -1;
    }
    g_tm.running = TRUE;
    g_tm.thread = g_thread_new("teams-media", media_thread, &g_tm);
    return 0;
}

static int tm_add_remote_candidate(const char *sdp_candidate)
{
    if (!g_tm.agent || !sdp_candidate) return -1;
    gchar *attr = (strncmp(sdp_candidate, "a=", 2) == 0) ? g_strdup(sdp_candidate)
                                                         : g_strconcat("a=", sdp_candidate, NULL);
    NiceCandidate *c = nice_agent_parse_remote_candidate_sdp(g_tm.agent, g_tm.stream_id, attr);
    g_free(attr);
    if (!c) { g_printerr("teams_media: bad remote candidate: %s\n", sdp_candidate); return -1; }
    GSList *l = g_slist_append(NULL, c);
    int added = nice_agent_set_remote_candidates(g_tm.agent, g_tm.stream_id, g_tm.component, l);
    g_slist_free(l); nice_candidate_free(c);
    g_message("teams_media: REMOTE candidate added=%d -> %s", added, sdp_candidate);
    return added > 0 ? 0 : -1;
}

static void tm_stop(void)
{
    if (!g_tm.running) return;
    g_tm.running = FALSE;
    if (g_tm.pipeline) gst_element_set_state(g_tm.pipeline, GST_STATE_NULL);
    if (g_tm.audiod_on && g_tm.audiod_cb) g_tm.audiod_cb(0);
    g_tm.audiod_on = FALSE;
    if (g_tm.loop) g_main_loop_quit(g_tm.loop);
    if (g_tm.thread) { g_thread_join(g_tm.thread); g_tm.thread = NULL; }
    if (g_tm.pipeline) { gst_object_unref(g_tm.pipeline); g_tm.pipeline = NULL; }
    if (g_tm.agent) { g_object_unref(g_tm.agent); g_tm.agent = NULL; }
    if (g_tm.rx_master) { gst_buffer_unref(g_tm.rx_master); g_tm.rx_master = NULL; }
    if (g_tm.tx_master) { gst_buffer_unref(g_tm.tx_master); g_tm.tx_master = NULL; }
    if (g_tm.loop) { g_main_loop_unref(g_tm.loop); g_tm.loop = NULL; }
    if (g_tm.ctx) { g_main_context_unref(g_tm.ctx); g_tm.ctx = NULL; }
}

/* ------------------------------------------------------------------ IPC ------------------------ */
#ifndef TEAMS_MEDIA_NO_MAIN

static GMutex g_out_lock;
static void emit(const char *fmt, ...)
{
    va_list ap; va_start(ap, fmt);
    g_mutex_lock(&g_out_lock); vfprintf(stdout, fmt, ap); fflush(stdout); g_mutex_unlock(&g_out_lock);
    va_end(ap);
}
static void ipc_cand(const char *sdp)  { emit("CAND %s\n", sdp); }
static void ipc_audiod(int active)     { emit("AUDIOD %d\n", active ? 1 : 0); }

static int run_ipc(void)
{
    char line[8192];
    int started = 0;
    setvbuf(stdout, NULL, _IOLBF, 0);
    g_mutex_init(&g_out_lock);

    while (fgets(line, sizeof line, stdin)) {
        char *nl = strchr(line, '\n'); if (nl) *nl = '\0';
        if (!line[0]) continue;

        if (strncmp(line, "RELAY ", 6) == 0) {
            char *sp = NULL;
            char *kind = strtok_r(line + 6, " ", &sp);
            char *host = strtok_r(NULL, " ", &sp);
            char *ports= strtok_r(NULL, " ", &sp);
            if (kind && host && ports) {
                int port = atoi(ports);
                if (!strcmp(kind, "stun")) { snprintf(g_stun_host, sizeof g_stun_host, "%s", host); g_stun_port = port; }
                else if (!strcmp(kind, "turn") && g_n_turn < TM_MAX_TURN) {
                    char *u = strtok_r(NULL, " ", &sp), *p = strtok_r(NULL, " ", &sp), *tr = strtok_r(NULL, " ", &sp);
                    TmTurn *t = &g_turn[g_n_turn++];
                    snprintf(t->host, sizeof t->host, "%s", host); t->port = port;
                    snprintf(t->user, sizeof t->user, "%s", u?u:""); snprintf(t->pass, sizeof t->pass, "%s", p?p:"");
                    t->type = (tr && !strcmp(tr,"tcp")) ? NICE_RELAY_TYPE_TURN_TCP
                            : (tr && !strcmp(tr,"tls")) ? NICE_RELAY_TYPE_TURN_TLS : NICE_RELAY_TYPE_TURN_UDP;
                }
            }
        } else if (strncmp(line, "START ", 6) == 0) {
            if (started) { emit("ERR already-started\n"); continue; }
            char *sp = NULL;
            char *rxk = strtok_r(line + 6, " ", &sp);
            char *ruf = strtok_r(NULL, " ", &sp);
            char *rpw = strtok_r(NULL, " ", &sp);
            char *pts = strtok_r(NULL, " ", &sp);
            if (!rxk || !ruf || !rpw) { emit("ERR start-missing-fields\n"); continue; }
            gchar *uf = NULL, *pw = NULL, *txk = NULL;
            int rc = tm_start(rxk, ruf, rpw, pts ? atoi(pts) : TM_DEFAULT_PT,
                              ipc_cand, ipc_audiod, &uf, &pw, &txk);
            if (rc != 0) { emit("ERR start-failed\n"); return 1; }
            emit("UFRAG %s\n", uf ? uf : "");
            emit("PWD %s\n",   pw ? pw : "");
            emit("TXKEY %s\n", txk ? txk : "");
            g_free(uf); g_free(pw); g_free(txk);
            started = 1;
            emit("READY\n");
        } else if (strncmp(line, "RCAND ", 6) == 0) {
            if (!started) { emit("ERR rcand-before-start\n"); continue; }
            tm_add_remote_candidate(line + 6);
        } else if (!strcmp(line, "STOP")) {
            break;
        } else {
            emit("ERR unknown-cmd\n");
        }
    }
    if (started) tm_stop();
    return 0;
}

/* ------------------------------------------------------------------ loopback ------------------- */
static int loopback(void)
{
    tm_init();
    guchar k[TM_GCM_MASTER_SIZE]; for (int i=0;i<TM_GCM_MASTER_SIZE;i++) k[i]=(guchar)(i+1);
    GstBuffer *master = master_buffer_from_bytes(k, TM_GCM_MASTER_SIZE);
    GMainLoop *loop = g_main_loop_new(NULL, FALSE);
    GstElement *pipe = gst_pipeline_new("lt");
    GstElement *src=mk("audiotestsrc","s"),*conv=mk("audioconvert","c"),*res=mk("audioresample","r"),
        *caps=mk("capsfilter","cf"),*oenc=mk("opusenc","oe"),*pay=mk("rtpopuspay","p"),
        *senc=mk("srtpenc","se"),*sdec=mk("srtpdec","sd"),*rxc=mk("capsfilter","rc"),
        *depay=mk("rtpopusdepay","dp"),*odec=mk("opusdec","od"),*sink=mk("fakesink","fs");
    if (!pipe||!src||!conv||!res||!caps||!oenc||!pay||!senc||!sdec||!rxc||!depay||!odec||!sink) {
        g_printerr("[loopback] missing element(s)\n"); return 3; }
    g_object_set(src, "is-live", TRUE, "num-buffers", 200, NULL);
    { GstCaps *c=gst_caps_new_simple("audio/x-raw","format",G_TYPE_STRING,"S16LE","rate",G_TYPE_INT,TM_OPUS_CLOCKRATE,"channels",G_TYPE_INT,TM_OPUS_CHANNELS,NULL);
      g_object_set(caps,"caps",c,NULL); gst_caps_unref(c); }
    g_object_set(pay,"pt",TM_DEFAULT_PT,NULL);
    configure_srtpenc(senc, master);
    g_tm.rx_master = gst_buffer_ref(master);
    g_signal_connect(sdec,"request-key",G_CALLBACK(on_srtpdec_request_key),&g_tm);
    { GstCaps *c=opus_rtp_caps(TM_DEFAULT_PT); g_object_set(rxc,"caps",c,NULL); gst_caps_unref(c); }
    g_object_set(sink,"sync",FALSE,"async",FALSE,NULL);
    gst_bin_add_many(GST_BIN(pipe),src,conv,res,caps,oenc,pay,senc,sdec,rxc,depay,odec,sink,NULL);
    if (!gst_element_link_many(src,conv,res,caps,oenc,pay,senc,NULL)||
        !gst_element_link_many(senc,sdec,NULL)||
        !gst_element_link_many(sdec,rxc,depay,odec,sink,NULL)) { g_printerr("[loopback] link failed\n"); return 4; }
    g_timeout_add_seconds(8,(GSourceFunc)g_main_loop_quit,loop);
    g_print("[loopback] SRTP-GCM+RTP+Opus round-trip...\n");
    gst_element_set_state(pipe,GST_STATE_PLAYING);
    g_main_loop_run(loop);
    gst_element_set_state(pipe,GST_STATE_NULL);
    g_print("[loopback] done (check for ERROR above; no error = PASS)\n");
    gst_object_unref(pipe); gst_buffer_unref(master); g_main_loop_unref(loop);
    return 0;
}

int main(int argc, char **argv)
{
    tm_init();
    if (argc >= 2 && (!strcmp(argv[1],"--loopback")||!strcmp(argv[1],"--selftest"))) return loopback();
    if (argc >= 2 && !strcmp(argv[1],"--answer")) return run_ipc();
    g_print("Teams call media engine (webOS).\n  %s --loopback\n  %s --answer\n", argv[0], argv[0]);
    return 0;
}
#endif
