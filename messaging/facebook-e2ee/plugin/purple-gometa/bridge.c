// bridge.c — the Go -> libpurple boundary. Go goroutines call gometa_process_message();
// it copies the struct to the heap and schedules gometa_dispatch() on the glib main
// thread (libpurple is single-threaded), which does the actual purple work and frees.
#include "bridge.h"
#include "constants.h" // GOMETA_PLUGIN_ID
#include <stdlib.h> // free
#include <time.h>   // time

// g_memdup2 replaces the deprecated g_memdup on newer glib; alias on older.
#if !GLIB_CHECK_VERSION(2, 68, 0)
#define g_memdup2 g_memdup
#endif

// The char* fields were allocated by cgo's C.CString (malloc), so free() them.
static void gometa_free_strings(gometa_message_t *m) {
    free(m->who);
    free(m->name);
    free(m->text);
    free(m->id);
}

// Runs on the glib main thread.
static gboolean gometa_dispatch(gpointer data) {
    gometa_message_t *m = (gometa_message_t *)data;
    PurpleConnection *pc = purple_account_get_connection(m->account);
    if (pc != NULL) {
        time_t ts = m->timestamp ? m->timestamp : time(NULL);
        switch (m->msgtype) {
            case gometa_message_type_connected:
                purple_connection_set_state(pc, PURPLE_CONNECTED);
                break;
            case gometa_message_type_disconnected:
                purple_connection_set_state(pc, PURPLE_DISCONNECTED);
                break;
            case gometa_message_type_error:
                if (m->fatal) {
                    purple_connection_error_reason(pc, PURPLE_CONNECTION_ERROR_NETWORK_ERROR,
                        m->text ? m->text : "Unknown error");
                } else {
                    purple_debug_error(GOMETA_PLUGIN_ID, "%s\n", m->text ? m->text : "error");
                }
                break;
            case gometa_message_type_text:
                if (m->who && m->text) {
                    serv_got_im(pc, m->who, m->text,
                        m->isOutgoing ? PURPLE_MESSAGE_SEND : PURPLE_MESSAGE_RECV, ts);
                }
                break;
            default:
                break;
        }
    }
    gometa_free_strings(m);
    g_free(m);
    return FALSE; // one-shot
}

// Called from Go (any goroutine).
void gometa_process_message(gometa_message_t msg) {
    gometa_message_t *heap = g_memdup2(&msg, sizeof msg);
    purple_timeout_add(0, gometa_dispatch, heap);
}
