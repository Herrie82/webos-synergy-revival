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
#include <gst/app/gstappsink.h>
#include <gst/app/gstappsrc.h>
#include <nice/agent.h>
#include <glib.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/mman.h>

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

/* ---- direct qspkd speaker output (bypasses the atlasqspksink element, which fails to activate in
 * the live call pipeline). We take decoded PCM off an appsink and write it straight to qspkd's unix
 * socket: header {magic,format,rate,channels} once, then raw interleaved S16LE. Same wire protocol as
 * libgstatlasqspksink.so; qspkd relays to system PulseAudio -> speaker. One client at a time. ---- */
#define QSPK_SOCK  "/tmp/qspkd.sock"
#define QSPK_MAGIC 0x5153504bU
#define QSPK_FMT_S16LE 0
struct qspk_hdr { guint32 magic, format, rate, channels; };
static int      g_qspk_fd = -1;
static gboolean g_qspk_hdr_sent = FALSE;

static gboolean qspk_send_all(int fd, const void *buf, gsize n)
{
    const guint8 *p = buf;
    while (n) {
        gssize w = send(fd, p, n, MSG_NOSIGNAL);
        if (w < 0) { if (errno == EINTR) continue; return FALSE; }
        p += w; n -= (gsize) w;
    }
    return TRUE;
}

static void qspk_close(void)
{
    if (g_qspk_fd >= 0) { close(g_qspk_fd); g_qspk_fd = -1; }
    g_qspk_hdr_sent = FALSE;
}

/* appsink "new-sample": pull decoded PCM, lazily connect to qspkd (sending the header from the
 * negotiated caps), then stream the raw samples. Runs on the RX streaming thread. */
static GstFlowReturn on_rx_sample(GstElement *sink, gpointer user)
{
    (void) user;
    GstSample *sample = gst_app_sink_pull_sample(GST_APP_SINK(sink));
    if (!sample) return GST_FLOW_OK;
    GstBuffer *buf = gst_sample_get_buffer(sample);
    GstCaps   *caps = gst_sample_get_caps(sample);
    GstMapInfo map;
    if (buf && caps && gst_buffer_map(buf, &map, GST_MAP_READ)) {
        if (g_qspk_fd < 0) {
            int fd = socket(AF_UNIX, SOCK_STREAM, 0);
            struct sockaddr_un a; memset(&a, 0, sizeof a); a.sun_family = AF_UNIX;
            g_strlcpy(a.sun_path, QSPK_SOCK, sizeof a.sun_path);
            if (fd >= 0 && connect(fd, (struct sockaddr *)&a, sizeof a) == 0) {
                g_qspk_fd = fd; g_qspk_hdr_sent = FALSE;
                tm_trace("qspk: connected to qspkd");
            } else { if (fd >= 0) close(fd); tm_trace("qspk: connect FAILED"); }
        }
        if (g_qspk_fd >= 0 && !g_qspk_hdr_sent) {
            GstStructure *s = gst_caps_get_structure(caps, 0);
            gint rate = 48000, ch = 1;
            gst_structure_get_int(s, "rate", &rate);
            gst_structure_get_int(s, "channels", &ch);
            struct qspk_hdr h = { QSPK_MAGIC, QSPK_FMT_S16LE, (guint32) rate, (guint32) ch };
            if (qspk_send_all(g_qspk_fd, &h, sizeof h)) {
                g_qspk_hdr_sent = TRUE;
                { char t[64]; g_snprintf(t, sizeof t, "qspk: header sent %dch %dHz", ch, rate); tm_trace(t); }
            } else { qspk_close(); }
        }
        if (g_qspk_fd >= 0 && g_qspk_hdr_sent) {
            if (!qspk_send_all(g_qspk_fd, map.data, map.size)) { tm_trace("qspk: write failed"); qspk_close(); }
        }
        gst_buffer_unmap(buf, &map);
    }
    gst_sample_unref(sample);
    return GST_FLOW_OK;
}

/* ---- direct qmicd mic capture (bypasses the qmicsrc element). The gst qmicsrc element connects fine,
 * but by the time OUR pipeline finishes gst state-change negotiation and its GstPushSrc task first
 * calls create(), qmicd's ring (8 slots x 20ms = 160ms deep) has already wrapped many times over -
 * every backlogged {seq,slot} message in the socket refers to a long-overwritten slot, so every read
 * hits the seqlock retry and exhausts GST_FLOW_ERROR. Reading the socket ourselves, on a dedicated
 * thread started the moment we begin building the pipeline (not gated on GStreamer reaching PLAYING),
 * avoids that backlog and feeds an appsrc instead. Same wire protocol as gstqmicsrc.c. ---- */
#define QMICD_SHM    "/tmp/qmicd.shm"
#define QMICD_SOCK   "/tmp/qmicd.sock"
#define QMICD_MAGIC  0x44494d51u
#define QMIC_SLOT0_OFF 4096u
#define QMIC_RATE    16000
#define QMIC_CH      1
#define QMIC_CHUNK_BYTES ((QMIC_RATE*QMIC_CH*2*20)/1000)   /* 20ms S16LE mono = 640B */
#define QMIC_NUM_SLOTS   8
#define QMIC_CHUNK_NS    (GST_SECOND/(1000/20))

struct qmicd_hdr { guint32 magic, rate, channels, fmt, chunk_bytes, num_slots, seq, pad; };
struct qmicd_chunk_msg { guint32 seq, slot; };

static int       g_qmic_fd = -1;
static guint8    *g_qmic_shm = NULL;
static gsize      g_qmic_shm_sz = 0;
static GThread   *g_qmic_thread = NULL;
static volatile gboolean g_qmic_running = FALSE;
static GstElement *g_qmic_appsrc = NULL;

static gboolean qmic_read_full(int fd, void *buf, gsize n)
{
    guint8 *p = buf; gsize got = 0;
    while (got < n) {
        ssize_t r = read(fd, p + got, n - got);
        if (r <= 0) { if (r < 0 && errno == EINTR) continue; return FALSE; }
        got += (gsize) r;
    }
    return TRUE;
}

static gpointer qmic_reader_thread(gpointer user)
{
    (void) user;
    struct qmicd_hdr *hdr = (struct qmicd_hdr *) g_qmic_shm;
    guint64 pts = 0;
    guint chunks = 0; gint16 peak = 0;
    tm_trace("qmic: reader thread started");
    while (g_qmic_running) {
        struct qmicd_chunk_msg msg;
        guint32 csz, seq_after;
        const guint8 *src;
        if (!qmic_read_full(g_qmic_fd, &msg, sizeof msg)) {
            tm_trace("qmic: qmicd closed connection"); break;
        }
        if (hdr->magic != QMICD_MAGIC) { tm_trace("qmic: bad shm magic"); break; }
        csz = hdr->chunk_bytes;
        if (!csz || csz > QMIC_CHUNK_BYTES || msg.slot >= hdr->num_slots) {
            tm_trace("qmic: bad chunk meta"); break;
        }
        src = g_qmic_shm + QMIC_SLOT0_OFF + (gsize) msg.slot * QMIC_CHUNK_BYTES;
        GstBuffer *buf = gst_buffer_new_allocate(NULL, csz, NULL);
        if (!buf) continue;
        gst_buffer_fill(buf, 0, src, csz);
        seq_after = hdr->seq;
        if (seq_after - msg.seq >= hdr->num_slots) {
            /* torn read (daemon wrapped onto this slot mid-copy) - drop this one, keep going */
            gst_buffer_unref(buf);
            continue;
        }
        GST_BUFFER_PTS(buf) = pts;
        GST_BUFFER_DURATION(buf) = QMIC_CHUNK_NS;
        pts += QMIC_CHUNK_NS;
        /* peak-amplitude sanity check: is qmicd handing us real audio or silence? logged 1x/sec. */
        { GstMapInfo m; if (gst_buffer_map(buf, &m, GST_MAP_READ)) {
            const gint16 *s = (const gint16 *) m.data; gsize n = m.size / 2;
            for (gsize i = 0; i < n; i++) { gint16 v = s[i] < 0 ? -s[i] : s[i]; if (v > peak) peak = v; }
            gst_buffer_unmap(buf, &m); } }
        if (++chunks >= 50) {   /* 50 * 20ms = 1s */
            char t[64]; g_snprintf(t, sizeof t, "qmic: 1s peak amplitude = %d/32767", peak);
            tm_trace(t); chunks = 0; peak = 0;
        }
        if (g_qmic_appsrc) {
            GstFlowReturn fr;
            g_signal_emit_by_name(g_qmic_appsrc, "push-buffer", buf, &fr);
        }
        gst_buffer_unref(buf);
    }
    tm_trace("qmic: reader thread exiting");
    return NULL;
}

/* Connect + mmap qmicd (starts the daemon's mic recording) and spawn the reader thread. Call as early
 * as possible (before/while the gst pipeline negotiates) so we start draining the ring immediately. */
static gboolean qmic_start(GstElement *appsrc)
{
    int fd, shm_fd;
    struct sockaddr_un addr;
    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { tm_trace("qmic: socket() failed"); return FALSE; }
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    g_strlcpy(addr.sun_path, QMICD_SOCK, sizeof addr.sun_path);
    if (connect(fd, (struct sockaddr *) &addr, sizeof addr) < 0) {
        tm_trace("qmic: connect FAILED (is qmicd running?)"); close(fd); return FALSE;
    }
    shm_fd = open(QMICD_SHM, O_RDONLY);
    if (shm_fd < 0) { tm_trace("qmic: open shm FAILED"); close(fd); return FALSE; }
    g_qmic_shm_sz = QMIC_SLOT0_OFF + (gsize) QMIC_NUM_SLOTS * QMIC_CHUNK_BYTES;
    g_qmic_shm = mmap(NULL, g_qmic_shm_sz, PROT_READ, MAP_SHARED, shm_fd, 0);
    close(shm_fd);
    if (g_qmic_shm == MAP_FAILED) { tm_trace("qmic: mmap FAILED"); g_qmic_shm = NULL; close(fd); return FALSE; }
    g_qmic_fd = fd;
    g_qmic_appsrc = appsrc;
    g_qmic_running = TRUE;
    g_qmic_thread = g_thread_new("qmic-reader", qmic_reader_thread, NULL);
    tm_trace("qmic: connected to qmicd; mic recording starting");
    return TRUE;
}

static void qmic_stop(void)
{
    if (!g_qmic_running && g_qmic_fd < 0) return;
    g_qmic_running = FALSE;
    if (g_qmic_fd >= 0) { shutdown(g_qmic_fd, SHUT_RDWR); }   /* unblock the reader thread's read() */
    if (g_qmic_thread) { g_thread_join(g_qmic_thread); g_qmic_thread = NULL; }
    if (g_qmic_fd >= 0) { close(g_qmic_fd); g_qmic_fd = -1; }
    if (g_qmic_shm) { munmap(g_qmic_shm, g_qmic_shm_sz); g_qmic_shm = NULL; }
    g_qmic_appsrc = NULL;
    tm_trace("qmic: stopped, mic released");
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
            { char t[1024]; g_snprintf(t, sizeof t, "PIPELINE ERROR %s: %s | dbg=%s",
                GST_OBJECT_NAME(msg->src), err ? err->message : "?", dbg ? dbg : "(none)"); tm_trace(t); }
            if (err) g_error_free(err);
            g_free(dbg);
            break;
        }
        case GST_MESSAGE_WARNING: {
            GError *err = NULL; gchar *dbg = NULL;
            gst_message_parse_warning(msg, &err, &dbg);
            { char t[1024]; g_snprintf(t, sizeof t, "PIPELINE WARN %s: %s | dbg=%s",
                GST_OBJECT_NAME(msg->src), err ? err->message : "?", dbg ? dbg : "(none)"); tm_trace(t); }
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
        { char t[320]; g_snprintf(t, sizeof t, "LOCAL cand: %.280s", bare); tm_trace(t); }
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

/* Build the agent, set remote creds (may be NULL for the caller at offer time), gather. Our local
 * creds are generated by libnice and read back by the caller of this fn (to emit UFRAG/PWD).
 * controlling = TRUE for the CALLER (outgoing), FALSE for the answerer (incoming). */
static gboolean build_ice(TeamsMedia *tm, gboolean controlling, const char *remote_ufrag, const char *remote_pwd)
{
    tm_trace("build_ice enter");
    /* NICE_COMPATIBILITY_RFC5245 = standard ICE. Teams' MS-ICE is close enough for host/srflx/relay
     * pairing in practice; if MS-specific quirks block it we may need MS-TURN via RELAY. */
    tm->agent = nice_agent_new(tm->ctx, NICE_COMPATIBILITY_RFC5245);
    if (!tm->agent) { g_printerr("teams_media: nice_agent_new failed\n"); return FALSE; }
    g_object_set(tm->agent, "controlling-mode", controlling ? TRUE : FALSE, NULL);

    /* THE incoming-ICE fix, ported from Signal (7dd3ab2): Teams' caller (WebRTC/RingRTC-style)
     * nominates the selected pair via Google's ICE RENOMINATION extension (GOOG-NOMINATION STUN
     * attr 0xC001), NOT the standard USE-CANDIDATE. libnice's controlled answerer forms a valid pair
     * but never nominates it without this -> ICE goes connecting -> FAILED (exactly our symptom).
     * libnice 0.1.21 implements it behind support-renomination (defaults FALSE). Enable it. */
    g_object_set(tm->agent, "support-renomination", TRUE, NULL);
    tm_trace("build_ice: support-renomination enabled");

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
    GstElement *rtcpfake = mk("fakesink",  "rx-rtcpfake");   /* discards rtcp-mux'd RTCP from srtpdec */
    GstElement *rxrtp = mk("capsfilter",   "rx-rtpcaps");
    GstElement *depay = mk("rtpopusdepay", "rx-depay");
    GstElement *odec  = mk("opusdec",      "rx-opusdec");
    GstElement *aconv = mk("audioconvert", "rx-aconv");
    GstElement *ares  = mk("audioresample","rx-ares");
    GstElement *rxs16 = mk("capsfilter",   "rx-s16");   /* force S16LE for the qspkd wire format */
    /* RX speaker output: appsink -> we write PCM straight to qspkd's socket (on_rx_sample). We use an
     * appsink instead of the atlasqspksink element because that element fails to ACTIVATE in the live
     * call pipeline (-> "not-linked"); appsink is a pure software sink that always accepts buffers, and
     * we control the qspkd socket lifecycle ourselves. qspkd -> system PulseAudio -> speaker. */
    GstElement *asink = mk("appsink", "rx-appsink");

    /* TX mic source: appsrc fed by our own qmicd reader thread (qmic_start), NOT the qmicsrc element -
     * see the qmic_start/qmic_reader_thread comment for why. /media/internal/teams-txtone forces a
     * diagnostic tone instead (kept for isolating ICE/RX from the mic path). */
    gboolean tx_tone = g_file_test("/media/internal/teams-txtone", G_FILE_TEST_EXISTS);
    GstElement *asrc  = mk(tx_tone ? "audiotestsrc" : "appsrc", "tx-src");
    GstElement *tconv = mk("audioconvert", "tx-aconv");
    GstElement *tres  = mk("audioresample","tx-ares");
    GstElement *tcap  = mk("capsfilter",   "tx-rawcaps");
    GstElement *oenc  = mk("opusenc",      "tx-opusenc");
    GstElement *pay   = mk("rtpopuspay",   "tx-pay");
    GstElement *senc  = mk("srtpenc",      "tx-srtpenc");
    GstElement *nsink = mk("nicesink",     "tx-nicesink");

    if (!nsrc||!rxcap||!sdec||!rxrtp||!depay||!odec||!aconv||!ares||!rxs16||!asink||!rtcpfake||
        !asrc||!tconv||!tres||!tcap||!oenc||!pay||!senc||!nsink) {
        if (tm->pipeline) { gst_object_unref(tm->pipeline); tm->pipeline = NULL; } return FALSE;
    }
    g_object_set(rtcpfake, "sync", FALSE, "async", FALSE, NULL);

    g_object_set(nsrc,  "agent", tm->agent, "stream", tm->stream_id, "component", tm->component, NULL);
    g_object_set(nsink, "agent", tm->agent, "stream", tm->stream_id, "component", tm->component, NULL);

    { GstCaps *c = gst_caps_new_empty_simple("application/x-srtp"); g_object_set(rxcap, "caps", c, NULL); gst_caps_unref(c); }
    g_signal_connect(sdec, "request-key", G_CALLBACK(on_srtpdec_request_key), tm);
    { GstCaps *c = opus_rtp_caps(tm->pt); g_object_set(rxrtp, "caps", c, NULL); gst_caps_unref(c); }
    { GstCaps *c = gst_caps_new_simple("audio/x-raw", "format", G_TYPE_STRING, "S16LE", NULL);
      g_object_set(rxs16, "caps", c, NULL); gst_caps_unref(c); }
    /* appsink: hand every decoded buffer to on_rx_sample (writes to qspkd). No clock sync - qspkd's
     * blocking pa_simple_write paces us to real time. */
    g_object_set(asink, "emit-signals", TRUE, "sync", FALSE, "max-buffers", 8, "drop", FALSE, NULL);
    g_signal_connect(asink, "new-sample", G_CALLBACK(on_rx_sample), &g_tm);

    { GstCaps *c = gst_caps_new_simple("audio/x-raw", "format", G_TYPE_STRING, "S16LE",
        "rate", G_TYPE_INT, TM_OPUS_CLOCKRATE, "channels", G_TYPE_INT, TM_OPUS_CHANNELS, NULL);
      g_object_set(tcap, "caps", c, NULL); gst_caps_unref(c); }
    /* audiotestsrc (tx-tone diagnostic) must be live + a quiet sine so Android hears we're sending.
     * appsrc (real mic) declares the qmicd wire format (16k mono S16LE); qmic_start() feeds it after
     * linking, from a thread that starts draining qmicd immediately (see qmic_start's comment). */
    if (tx_tone) {
        g_object_set(asrc, "is-live", TRUE, "wave", 0 /*sine*/, "freq", 440.0, "volume", 0.2, NULL);
    } else {
        GstCaps *c = gst_caps_new_simple("audio/x-raw", "format", G_TYPE_STRING, "S16LE",
            "rate", G_TYPE_INT, QMIC_RATE, "channels", G_TYPE_INT, QMIC_CH, "layout", G_TYPE_STRING, "interleaved", NULL);
        g_object_set(asrc, "caps", c, "is-live", TRUE, "format", GST_FORMAT_TIME, "block", FALSE, NULL);
        gst_caps_unref(c);
    }
    g_object_set(pay,  "pt", tm->pt, NULL);
    configure_srtpenc(senc, tm->tx_master);

    gst_bin_add_many(GST_BIN(tm->pipeline),
        nsrc, rxcap, sdec, rxrtp, depay, odec, aconv, ares, rxs16, asink, rtcpfake,
        asrc, tconv, tres, tcap, oenc, pay, senc, nsink, NULL);

    if (!gst_element_link_many(nsrc, rxcap, sdec, rxrtp, depay, odec, aconv, ares, rxs16, asink, NULL)) {
        g_printerr("teams_media: RX link failed\n"); return FALSE; }
    /* srtpdec has a STATIC "always" rtcp_src pad (rtcp-mux'd RTCP, decrypted). link_many only touched
     * rtp_src, so rtcp_src stays unlinked -> its push returns NOT_LINKED and kills the RX chain. Drain
     * it to the fakesink explicitly (get_static_pad, since it exists at creation - no pad-added). */
    { GstPad *rtcp = gst_element_get_static_pad(sdec, "rtcp_src");
      GstPad *fsink = gst_element_get_static_pad(rtcpfake, "sink");
      if (rtcp && fsink)
          tm_trace(gst_pad_link(rtcp, fsink) == GST_PAD_LINK_OK ? "rtcp_src -> fakesink linked"
                                                                : "rtcp_src -> fakesink link FAILED");
      else tm_trace("rtcp_src/fakesink pad missing");
      if (rtcp) gst_object_unref(rtcp);
      if (fsink) gst_object_unref(fsink); }
    if (!gst_element_link_many(asrc, tconv, tres, tcap, oenc, pay, senc, nsink, NULL)) {
        g_printerr("teams_media: TX link failed\n"); return FALSE; }
    if (!tx_tone) qmic_start(asrc);   /* begin draining qmicd now, ahead of PLAYING, to avoid backlog */

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
static gboolean g_is_caller = FALSE;

/* Bring the pipeline up (needs rx_master set). Shared by the answerer path and, for the caller, by
 * tm_apply_answer once the peer's answer arrives. */
static int tm_run_pipeline(void)
{
    if (!build_pipeline(&g_tm)) return -1;
    if (gst_element_set_state(g_tm.pipeline, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE) {
        g_printerr("teams_media: set PLAYING failed\n"); return -1;
    }
    if (!g_tm.thread) { g_tm.running = TRUE; g_tm.thread = g_thread_new("teams-media", media_thread, &g_tm); }
    return 0;
}

/* is_caller=0 (answerer): rx_master from the OFFER, pipeline starts now.
 * is_caller=1 (caller):   rx_master_b64/remote_* are NULL; we generate the TX key + local ICE and
 *                         emit them for our OFFER, but DEFER the pipeline until tm_apply_answer(). */
static int tm_start(int is_caller, const char *rx_master_b64, const char *remote_ufrag,
                    const char *remote_pwd, int pt,
                    void (*cand_cb)(const char*), void (*audiod_cb)(int),
                    gchar **out_ufrag, gchar **out_pwd, gchar **out_txkey_b64)
{
    tm_init();
    memset(&g_tm, 0, sizeof g_tm);
    g_tm.cand_cb = cand_cb; g_tm.audiod_cb = audiod_cb;
    g_tm.pt = pt > 0 ? pt : TM_DEFAULT_PT;
    g_is_caller = is_caller ? TRUE : FALSE;

    if (!is_caller) {
        gsize rxlen = 0;
        guchar *rxk = g_base64_decode(rx_master_b64, &rxlen);
        if (!rxk || rxlen < 32) { g_free(rxk); g_printerr("teams_media: bad rx master\n"); return -1; }
        g_tm.rx_master = master_buffer_from_bytes(rxk, rxlen);
        g_free(rxk);
    }

    /* TX master: 44 random bytes, emitted as base64 for our a=crypto (offer or answer). */
    guchar txk[TM_GCM_MASTER_SIZE];
    for (int i = 0; i < TM_GCM_MASTER_SIZE; i++) txk[i] = (guchar)(g_random_int() & 0xff);
    g_tm.tx_master = master_buffer_from_bytes(txk, TM_GCM_MASTER_SIZE);
    if (out_txkey_b64) *out_txkey_b64 = g_base64_encode(txk, TM_GCM_MASTER_SIZE);

    g_tm.ctx  = g_main_context_new();
    g_tm.loop = g_main_loop_new(g_tm.ctx, FALSE);

    if (!build_ice(&g_tm, is_caller, remote_ufrag, remote_pwd)) return -1;

    { gchar *uf = NULL, *pw = NULL;
      nice_agent_get_local_credentials(g_tm.agent, g_tm.stream_id, &uf, &pw);
      if (out_ufrag) *out_ufrag = uf; else g_free(uf);
      if (out_pwd)   *out_pwd   = pw; else g_free(pw); }

    /* Caller: run the media loop now (so ICE gathering + trickle fire) but DEFER the gst pipeline
     * until we have the answer's RX key. Answerer: bring the pipeline up immediately. */
    if (is_caller) {
        g_tm.running = TRUE;
        g_tm.thread = g_thread_new("teams-media", media_thread, &g_tm);
        return 0;
    }
    return tm_run_pipeline();
}

/* Caller side: the peer's ANSWER arrived - set the RX master (from the answer's a=crypto), the
 * remote ICE creds, and bring the pipeline up. */
static int tm_apply_answer(const char *rx_master_b64, const char *remote_ufrag, const char *remote_pwd)
{
    gsize rxlen = 0; guchar *rxk;
    if (!g_tm.agent) return -1;
    rxk = g_base64_decode(rx_master_b64, &rxlen);
    if (!rxk || rxlen < 32) { g_free(rxk); tm_trace("apply_answer: bad rx master"); return -1; }
    g_tm.rx_master = master_buffer_from_bytes(rxk, rxlen);
    g_free(rxk);
    if (remote_ufrag && remote_pwd)
        nice_agent_set_remote_credentials(g_tm.agent, g_tm.stream_id, remote_ufrag, remote_pwd);
    tm_trace("apply_answer: rx key + remote creds set, starting pipeline");
    return tm_run_pipeline();
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
    { char t[320]; g_snprintf(t, sizeof t, "REMOTE cand added=%d: %.270s", added, sdp_candidate); tm_trace(t); }
    return added > 0 ? 0 : -1;
}

static void tm_stop(void)
{
    if (!g_tm.running) return;
    g_tm.running = FALSE;
    qmic_stop();    /* stop the mic reader BEFORE the pipeline (it pushes into the appsrc) */
    if (g_tm.pipeline) gst_element_set_state(g_tm.pipeline, GST_STATE_NULL);
    qspk_close();   /* release the qspkd socket (one client at a time) */
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

static int run_ipc(int is_caller)
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
        } else if (strncmp(line, "START", 5) == 0) {
            if (started) { emit("ERR already-started\n"); continue; }
            char *sp = NULL; int rc; gchar *uf = NULL, *pw = NULL, *txk = NULL;
            strtok_r(line, " ", &sp);   /* consume "START" */
            if (is_caller) {
                /* CALLER: no rx key/remote yet - we produce the OFFER. START [pt] */
                char *pts = strtok_r(NULL, " ", &sp);
                rc = tm_start(1, NULL, NULL, NULL, pts ? atoi(pts) : TM_DEFAULT_PT,
                              ipc_cand, ipc_audiod, &uf, &pw, &txk);
            } else {
                /* ANSWERER: START <rxkey_b64> <rem_ufrag> <rem_pwd> [pt] */
                char *rxk = strtok_r(NULL, " ", &sp);
                char *ruf = strtok_r(NULL, " ", &sp);
                char *rpw = strtok_r(NULL, " ", &sp);
                char *pts = strtok_r(NULL, " ", &sp);
                if (!rxk || !ruf || !rpw) { emit("ERR start-missing-fields\n"); continue; }
                rc = tm_start(0, rxk, ruf, rpw, pts ? atoi(pts) : TM_DEFAULT_PT,
                              ipc_cand, ipc_audiod, &uf, &pw, &txk);
            }
            if (rc != 0) { emit("ERR start-failed\n"); return 1; }
            emit("UFRAG %s\n", uf ? uf : "");
            emit("PWD %s\n",   pw ? pw : "");
            emit("TXKEY %s\n", txk ? txk : "");
            g_free(uf); g_free(pw); g_free(txk);
            started = 1;
            emit("READY\n");
        } else if (strncmp(line, "ANSWER ", 7) == 0) {
            /* CALLER: the peer's answer arrived. ANSWER <rxkey_b64> <rem_ufrag> <rem_pwd> */
            char *sp = NULL;
            char *rxk = strtok_r(line + 7, " ", &sp);
            char *ruf = strtok_r(NULL, " ", &sp);
            char *rpw = strtok_r(NULL, " ", &sp);
            if (rxk) { tm_apply_answer(rxk, ruf, rpw); emit("ANSWERED\n"); }
            else emit("ERR answer-missing-fields\n");
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

/* Isolation tests for the qspkd/qmicd audio bridge (no ICE/SRTP). */
static int audiotest(int mic)
{
    tm_init();
    GMainLoop *loop = g_main_loop_new(NULL, FALSE);
    GstElement *pipe = gst_pipeline_new("at");
    /* mic=0: audiotestsrc tone -> speaker; mic=1: real mic (qmicsrc) -> speaker (loopback) */
    GstElement *src  = mk(mic ? "qmicsrc" : "audiotestsrc", "src");
    GstElement *conv = mk("audioconvert",  "conv");
    GstElement *res  = mk("audioresample", "res");
    GstElement *sink = mk("atlasqspksink", "sink");
    if (!pipe||!src||!conv||!res||!sink) { g_printerr("[audiotest] missing element(s)\n"); return 3; }
    if (!mic) g_object_set(src, "is-live", TRUE, "wave", 0 /*sine*/, "freq", 440.0, NULL);
    g_object_set(sink, "sync", FALSE, NULL);
    gst_bin_add_many(GST_BIN(pipe), src, conv, res, sink, NULL);
    if (!gst_element_link_many(src, conv, res, sink, NULL)) { g_printerr("[audiotest] link failed\n"); return 4; }
    { GstBus *b = gst_pipeline_get_bus(GST_PIPELINE(pipe)); gst_bus_add_watch(b, on_bus, &g_tm); gst_object_unref(b); }
    g_timeout_add_seconds(8, (GSourceFunc)g_main_loop_quit, loop);
    g_print("[audiotest] %s -> atlasqspksink for 8s (listen for %s)...\n",
            mic ? "qmicsrc" : "audiotestsrc", mic ? "your voice echoed" : "a 440Hz tone");
    tm_trace(mic ? "audiotest: qmicsrc->qspk" : "audiotest: tone->qspk");
    gst_element_set_state(pipe, GST_STATE_PLAYING);
    g_main_loop_run(loop);
    gst_element_set_state(pipe, GST_STATE_NULL);
    g_print("[audiotest] done\n");
    gst_object_unref(pipe); g_main_loop_unref(loop);
    return 0;
}

int main(int argc, char **argv)
{
    tm_init();
    if (argc >= 2 && (!strcmp(argv[1],"--loopback")||!strcmp(argv[1],"--selftest"))) return loopback();
    if (argc >= 2 && !strcmp(argv[1],"--qspktest")) return audiotest(0);
    if (argc >= 2 && !strcmp(argv[1],"--mictest"))  return audiotest(1);
    if (argc >= 2 && !strcmp(argv[1],"--answer")) return run_ipc(0);
    if (argc >= 2 && !strcmp(argv[1],"--caller")) return run_ipc(1);
    g_print("Teams call media engine (webOS).\n  %s --loopback\n  %s --answer\n  %s --caller\n", argv[0], argv[0], argv[0]);
    return 0;
}
#endif
