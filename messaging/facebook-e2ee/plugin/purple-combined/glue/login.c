#include "gowhatsapp.h"
#include "libwhatsmeow.h" // for gowhatsapp_go_login / gowhatsapp_go_send_reaction / gometa_go_send_reaction
#include "call.h"         // for whatsapp_call_luna_init (WhatsApp voice calling LS2 service)
#include "../gometabridge.h" // for GOMETA_PLUGIN_ID

// webOS reactions (SEND): the transport emits "webos-im-send-reaction" (registered process-wide) when
// the user reacts from the TouchPad. It fires for EVERY account, so we filter by protocol id and route
// to the matching Go send-reaction handler. Params (5): account, targetServiceMessageId, emoji (already
// decoded UTF-8, always supplied even on removal), peer (the thread/chat id the transport uses),
// removeFlag ("1" = remove my reaction, else add). This one .so hosts BOTH prpls (WhatsApp + gometa),
// so the same callback covers both.
static void webos_send_reaction_cb(PurpleAccount *account, const char *targetId, const char *emoji,
                                   const char *peer, const char *removeFlag, void *data)
{
    (void)data;
    if (!account || !targetId || !*targetId) {
        return;
    }
    const char *proto = purple_account_get_protocol_id(account);
    if (g_strcmp0(proto, GOWHATSAPP_PRPL_ID) == 0) {
        gowhatsapp_go_send_reaction(account, (char *)targetId, (char *)(emoji ? emoji : ""),
                                    (char *)(peer ? peer : ""), (char *)(removeFlag ? removeFlag : ""));
    } else if (g_strcmp0(proto, GOMETA_PLUGIN_ID) == 0) {
        gometa_go_send_reaction(account, (char *)targetId, (char *)(emoji ? emoji : ""),
                                (char *)(peer ? peer : ""), (char *)(removeFlag ? removeFlag : ""));
    }
}

// Connect once (process-wide) to the transport's send-reaction signal. The signal lives on
// purple_conversations_get_handle(), so a single connect covers every account of both prpls in this
// process. Called from BOTH login paths (gowhatsapp_login here and gometa_login) so it fires whether
// the user has a WhatsApp account, a Facebook account, or both; the static guard prevents a double
// connect. The transport registers the signal at init, before any account logs in.
void webos_connect_send_reaction_once(void)
{
    static gboolean s_connected = FALSE;
    if (s_connected) {
        return;
    }
    s_connected = TRUE;
    purple_signal_connect(purple_conversations_get_handle(), "webos-im-send-reaction",
                          purple_get_core(), PURPLE_CALLBACK(webos_send_reaction_cb), NULL);
}

void
gowhatsapp_login(PurpleAccount *account)
{
    PurpleConnection *pc = purple_account_get_connection(account);
    
    // this protocol does not support anything special right now
    PurpleConnectionFlags pc_flags;
    pc_flags = purple_connection_get_flags(pc);
    pc_flags |= PURPLE_CONNECTION_NO_IMAGES;
    pc_flags |= PURPLE_CONNECTION_NO_FONTSIZE;
    pc_flags |= PURPLE_CONNECTION_NO_BGCOLOR;
    purple_connection_set_flags(pc, pc_flags);

    purple_connection_set_state(pc, PURPLE_CONNECTION_CONNECTING);
    
    WhatsappProtocolData *wpd = g_new0(WhatsappProtocolData, 1); // MEMCHECK: released in gowhatsapp_close
    purple_connection_set_protocol_data(pc, wpd);

    // keep track on when the connection was (requested to be) established for discarding old messages
    wpd->connected_at_timestamp = time(NULL) - 1;
    
    char *proxy_address = NULL;
    PurpleProxyInfo *proxy_info = purple_proxy_get_setup(account);
    if (proxy_info != NULL && purple_proxy_info_get_type(proxy_info) != PURPLE_PROXY_NONE) {
        if (purple_proxy_info_get_type(proxy_info) != PURPLE_PROXY_SOCKS5) {
            purple_connection_error(pc, PURPLE_CONNECTION_ERROR_OTHER_ERROR, "socks5 is the only supported proxy scheme.");
            return;
        }
        // TODO: find out if there is an opposite to purple_url_parse
        // or forward proxy_info into go and use client.SetProxy
        const char *proxy_username = purple_proxy_info_get_username(proxy_info);
        const char *proxy_password = purple_proxy_info_get_password(proxy_info);
        const char *proxy_host = purple_proxy_info_get_host(proxy_info);
        int proxy_port = purple_proxy_info_get_port(proxy_info);
        GString * proxy_string = g_string_new(proxy_host); // MEMCHECK: proxy_address takes ownership
        if (proxy_username && proxy_username[0]) {
            proxy_string = g_string_prepend_c(proxy_string, '@');
            if (proxy_password && proxy_password[0]) {
                proxy_string = g_string_prepend(proxy_string, proxy_password);
                proxy_string = g_string_prepend_c(proxy_string, ':');
            }
            proxy_string = g_string_prepend(proxy_string, proxy_username);
        }
        proxy_string = g_string_append_c(proxy_string, ':');
        g_string_append_printf(proxy_string, "%d", proxy_port);
        proxy_string = g_string_prepend(proxy_string, "socks5://");
        proxy_address = g_string_free(proxy_string, FALSE); // MEMCHECK: free'd here
        purple_debug_info(GOWHATSAPP_NAME, "Using proxy address %s.\n", proxy_address);
    } else {
        purple_debug_info(GOWHATSAPP_NAME, "No proxy set in purple. The go runtime might pick up the https_proxy environment variable regardless.\n");
        // TODO: To disable reading proxy info from environment variables, use cli.SetProxy(nil)
    }
    
    const char *credentials = purple_account_get_string(account, GOWHATSAPP_CREDENTIALS_KEY, NULL);
    if (credentials == NULL) {
        credentials = purple_account_get_password(account); // bitlbee stores credentials in password field
    }
    char *username = (char *)purple_account_get_username(account); // cgo does not suport const
    char *user_dir = (char *)purple_user_dir(); // cgo does not suport const
    gowhatsapp_go_login(account, user_dir, username, (char *)credentials, proxy_address); // cgo does not suport const
    // webOS: register the com.palm.whatsapp.call LS2 service so the stock Phone app can place/receive
    // WhatsApp calls over this shared session (the Go side attaches meowcaller in startCalling).
    // Idempotent (guarded by g_registered) across accounts/reconnects. Was missing from the combined
    // plugin's login path, so com.palm.whatsapp.call never registered -> "service is not running".
    whatsapp_call_luna_init();
    g_free(proxy_address);

    gowhatsapp_receipts_init(pc);
    webos_connect_send_reaction_once();
}

void
gowhatsapp_close(PurpleConnection *pc)
{
    PurpleAccount * account = purple_connection_get_account(pc);
    char *username = (char *)purple_account_get_username(account); // cgo does not suport const
    char *user_dir = (char *)purple_user_dir(); // cgo does not suport const
    gowhatsapp_go_close(account, user_dir, username);
    
    WhatsappProtocolData *wpd = (WhatsappProtocolData *)purple_connection_get_protocol_data(pc);
    purple_connection_set_protocol_data(pc, NULL);
    g_free(wpd);
}

void
gowhatsapp_store_credentials(PurpleAccount *account, char *credentials)
{
    // Pidgin stores the credentials in the account settings
    // since commit ee89203, spectrum supports this out of the box
    // in bitlbee, this has no effect
    // TODO: ask spectrum maintainer if storing in password would okay, too
    // or do not store credentials at all (just use the username for look-up)
    purple_account_set_string(account, GOWHATSAPP_CREDENTIALS_KEY, credentials);
    
    // bitlbee stores credentials in password field
    purple_account_set_password(account, credentials);
    purple_signal_emit(
        purple_accounts_get_handle(),
        "bitlbee-set-account-password",
        account,
        credentials
    );
}
