// gometabridge.c — the Go->purple boundary for the Facebook half. Mirrors the whatsmeow
// bridge.c pattern (g_memdup2 + purple_timeout_add to the glib main thread), gometa_-prefixed.
#include "gometabridge.h"
#include <stdlib.h> // free/malloc
#include <string.h> // strdup
#include <time.h>   // time

// Forward-declare the cgo export (declared in the go-generated libwhatsmeow.h, which does
// not exist yet when cgo compiles this file in stage 1). Signature must match the //export.
extern void gometa_go_submit_input(PurpleAccount *account, char *value);

#if !GLIB_CHECK_VERSION(2, 68, 0)
#define g_memdup2 g_memdup
#endif

// ---- account settings (cache the login session) ----
char *gometa_get_setting(PurpleAccount *account, const char *key) {
    const char *v = purple_account_get_string(account, key, NULL);
    return (v && *v) ? strdup(v) : NULL;
}
void gometa_set_setting(PurpleAccount *account, const char *key, const char *value) {
    purple_account_set_string(account, key, value ? value : "");
}

// ---- interactive login prompt (2FA/captcha) ----
struct gometa_req { PurpleAccount *account; char *prompt; };

static void gometa_input_ok(void *user_data, const char *value) {
    gometa_go_submit_input((PurpleAccount *)user_data, (char *)(value ? value : ""));
}
static void gometa_input_cancel(void *user_data) {
    gometa_go_submit_input((PurpleAccount *)user_data, (char *)"");
}
static gboolean gometa_do_request(gpointer data) {
    struct gometa_req *r = (struct gometa_req *)data;
    PurpleConnection *gc = purple_account_get_connection(r->account);
    purple_request_input(gc, "Facebook login", r->prompt, NULL, NULL, FALSE, FALSE, NULL,
        "OK", G_CALLBACK(gometa_input_ok), "Cancel", G_CALLBACK(gometa_input_cancel),
        r->account, NULL, NULL, r->account);
    free(r->prompt);
    g_free(r);
    return FALSE;
}
void gometa_request_input(PurpleAccount *account, const char *prompt) {
    struct gometa_req *r = g_new0(struct gometa_req, 1);
    r->account = account;
    r->prompt = strdup(prompt ? prompt : "");
    purple_timeout_add(0, gometa_do_request, r);
}

static void gometa_free_strings(gometa_message_t *m) {
    free(m->who);
    free(m->conv);
    free(m->name);
    free(m->text);
    free(m->id);
}

// The buddy-list group all Facebook contacts/chats live under.
PurpleGroup *gometa_blist_group(void) {
    PurpleGroup *g = purple_find_group("Facebook");
    if (!g) { g = purple_group_new("Facebook"); purple_blist_add_group(g, NULL); }
    return g;
}

static void gometa_ensure_buddy(PurpleAccount *account, const char *id, const char *name) {
    if (!id || !*id) return;
    PurpleBuddy *b = purple_find_buddy(account, id);
    if (!b) {
        b = purple_buddy_new(account, id, name);
        purple_blist_add_buddy(b, NULL, gometa_blist_group(), NULL);
    }
    if (name && *name) {
        serv_got_alias(purple_account_get_connection(account), id, name);
        purple_blist_node_set_string(&b->node, "server_alias", name);
    }
}

// Register a group thread as a blist chat (component "id" = thread key, used by find_blist_chat).
static void gometa_ensure_chat(PurpleAccount *account, const char *threadKey, const char *name) {
    if (!threadKey || !*threadKey) return;
    PurpleChat *chat = purple_blist_find_chat(account, name && *name ? name : threadKey);
    if (!chat) {
        GHashTable *comp = g_hash_table_new_full(g_str_hash, g_str_equal, NULL, g_free);
        g_hash_table_insert(comp, (gpointer)"id", g_strdup(threadKey));
        chat = purple_chat_new(account, name && *name ? name : threadKey, comp);
        purple_blist_add_chat(chat, gometa_blist_group(), NULL);
    } else if (name && *name) {
        purple_blist_alias_chat(chat, name);
    }
}

static void gometa_group_message(PurpleConnection *pc, const char *threadKey, const char *senderName,
                                 const char *text, time_t ts, int isOutgoing) {
    int chat_id = (int)g_str_hash(threadKey);
    if (purple_find_chat(pc, chat_id) == NULL) {
        serv_got_joined_chat(pc, chat_id, threadKey);
    }
    const char *from = (senderName && *senderName) ? senderName : "unknown";
    serv_got_chat_in(pc, chat_id, from, isOutgoing ? PURPLE_MESSAGE_SEND : PURPLE_MESSAGE_RECV, text, ts);
}

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
            case gometa_message_type_buddy:
                gometa_ensure_buddy(m->account, m->who, m->name);
                break;
            case gometa_message_type_chat:
                gometa_ensure_chat(m->account, m->conv, m->name);
                break;
            case gometa_message_type_presence:
                if (m->who && *m->who) {
                    purple_prpl_got_user_status(m->account, m->who,
                        m->isOutgoing ? "available" : "offline", NULL);
                }
                break;
            case gometa_message_type_text:
                if (m->text && m->conv) {
                    if (m->isGroup) {
                        gometa_group_message(pc, m->conv, m->name ? m->name : m->who, m->text, ts, m->isOutgoing);
                    } else if (m->isOutgoing) {
                        // own 1:1 message: serv_got_im forces RECV, so write to the IM conv directly
                        PurpleConversation *conv = purple_find_conversation_with_account(PURPLE_CONV_TYPE_IM, m->conv, m->account);
                        if (!conv) conv = purple_conversation_new(PURPLE_CONV_TYPE_IM, m->account, m->conv);
                        purple_conv_im_write(purple_conversation_get_im_data(conv), m->conv, m->text, PURPLE_MESSAGE_SEND, ts);
                    } else {
                        serv_got_im(pc, m->conv, m->text, PURPLE_MESSAGE_RECV, ts);
                    }
                }
                break;
            default:
                break;
        }
    }
    gometa_free_strings(m);
    g_free(m);
    return FALSE;
}

void gometa_process_message(gometa_message_t msg) {
    gometa_message_t *heap = g_memdup2(&msg, sizeof msg);
    purple_timeout_add(0, gometa_dispatch, heap);
}
