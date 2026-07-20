// init.c — registers the Meta (Facebook Messenger + E2EE) protocol with libpurple and
// wires its login/close/send_im callbacks to the exported Go functions.
#include "bridge.h"      // gometa_message_t, purple.h
#include "constants.h"   // GOMETA_PLUGIN_ID / _NAME
#include "libgometa.h"   // gometa_go_login / gometa_go_close / gometa_go_send_message (cgo)

#ifndef PLUGIN_VERSION
#define PLUGIN_VERSION 0.0.0
#endif
#define MAKE_STR(x) _MAKE_STR(x)
#define _MAKE_STR(x) #x

static const char *
gometa_list_icon(PurpleAccount *account, PurpleBuddy *buddy)
{
    return "facebook";
}

static GList *
gometa_status_types(PurpleAccount *account)
{
    GList *types = NULL;
    PurpleStatusType *t;
    // AVAILABLE + OFFLINE are the minimum needed for the account to go "online".
    t = purple_status_type_new_full(PURPLE_STATUS_AVAILABLE, NULL, NULL, TRUE, TRUE, FALSE);
    types = g_list_append(types, t);
    t = purple_status_type_new_full(PURPLE_STATUS_OFFLINE, NULL, NULL, TRUE, TRUE, FALSE);
    types = g_list_append(types, t);
    return types;
}

// purple login(): hand the account password (a Facebook cookie JSON blob) to Go.
static void
gometa_login(PurpleAccount *account)
{
    PurpleConnection *pc = purple_account_get_connection(account);
    purple_connection_set_state(pc, PURPLE_CONNECTING);

    const char *cookies = purple_account_get_password(account);
    char *username = (char *)purple_account_get_username(account); // cgo has no const
    char *user_dir = (char *)purple_user_dir();
    gometa_go_login(account, user_dir, username, (char *)(cookies ? cookies : ""), (char *)"");
}

static void
gometa_close(PurpleConnection *pc)
{
    gometa_go_close(purple_connection_get_account(pc));
}

static int
gometa_send_im(PurpleConnection *pc, const char *who, const char *message, PurpleMessageFlags flags)
{
    return gometa_go_send_message(purple_connection_get_account(pc), (char *)who, (char *)message);
}

static gboolean
libpurple2_plugin_load(PurplePlugin *plugin)
{
    return TRUE;
}

static PurplePluginProtocolInfo prpl_info = {
    .struct_size = sizeof(PurplePluginProtocolInfo),
    // password holds the cookie JSON; keep it required (no OPT_PROTO_NO_PASSWORD).
    .options = OPT_PROTO_IM_IMAGE,
    .list_icon = gometa_list_icon,
    .status_types = gometa_status_types,
    .login = gometa_login,
    .close = gometa_close,
    .send_im = gometa_send_im,
};

static void
plugin_init(PurplePlugin *plugin)
{
}

static PurplePluginInfo info = {
    .magic = PURPLE_PLUGIN_MAGIC,
    .major_version = PURPLE_MAJOR_VERSION,
    .minor_version = PURPLE_MINOR_VERSION,
    .type = PURPLE_PLUGIN_PROTOCOL,
    .priority = PURPLE_PRIORITY_DEFAULT,
    .id = GOMETA_PLUGIN_ID,
    .name = GOMETA_PLUGIN_NAME,
    .version = MAKE_STR(PLUGIN_VERSION),
    .summary = GOMETA_PLUGIN_SUMMARY,
    .description = GOMETA_PLUGIN_SUMMARY,
    .author = GOMETA_AUTHOR,
    .homepage = "https://github.com/mautrix/meta",
    .load = libpurple2_plugin_load,
    .extra_info = &prpl_info,
};

PURPLE_INIT_PLUGIN(gometa, plugin_init, info)
