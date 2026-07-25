package main

import (
	"context"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
)

/*
 * WhatsApp Channels (newsletters) support.
 *
 * whatsmeow delivers a followed Channel as a 1:1 message whose peer JID is "<id>@newsletter", and it
 * carries no channel name - the only name on a message is the SENDER push-name, which is empty for a
 * channel. So without help the buddy is created showing the raw "<id>@newsletter" JID.
 *
 * The readable title lives in the newsletter metadata, reachable only via an explicit query. Fetch the
 * account's subscribed channels once on connect and push each real name through purple_update_name -
 * the same sink used for contact push-names. That both CREATES the newsletter buddy (so followed but
 * quiet channels still show up) and ALIASES it with its real title, which the webOS transport then
 * files under the "WhatsApp Channels" server.
 */
func (handler *Handler) fetch_newsletter_names() {
	cli := handler.client
	if cli == nil {
		return
	}
	metas, err := cli.GetSubscribedNewsletters(context.TODO())
	if err != nil {
		handler.log.Warnf("GetSubscribedNewsletters failed: %#v", err)
		return
	}
	handler.log.Infof("Fetched %d subscribed WhatsApp Channels.", len(metas))
	for _, meta := range metas {
		if meta == nil {
			continue
		}
		name := meta.ThreadMeta.Name.Text
		if name == "" {
			continue
		}
		// meta.ID is the "<id>@newsletter" JID; purple_update_name creates/aliases the buddy under it.
		purple_update_name(handler.account, meta.ID.String(), name)
	}
}

/*
 * Fetch a WhatsApp Channel's recent history on demand. Called when the user opens the channel in the
 * Servers tab: the transport's openChannel -> serv_join_chat -> gowhatsapp_join_chat routes a
 * "<id>@newsletter" join here (a newsletter has no MUC to enter). We pull the last 50 posts via
 * whatsmeow and replay each through the normal handle_message path, so text/media extraction and the
 * newsletter->"WhatsApp Channels" routing (LibpurpleAdapter incoming_message_cb) are all reused.
 */
func (handler *Handler) fetch_newsletter_history(jidStr string) {
	cli := handler.client
	if cli == nil {
		return
	}
	jid, err := parseJID(jidStr)
	if err != nil {
		handler.log.Warnf("newsletter history: invalid jid %s: %#v", jidStr, err)
		return
	}
	msgs, err := cli.GetNewsletterMessages(context.TODO(), jid, &whatsmeow.GetNewsletterMessagesParams{Count: 50})
	if err != nil {
		handler.log.Warnf("GetNewsletterMessages(%s) failed: %#v", jidStr, err)
		return
	}
	handler.log.Infof("Fetched %d history messages for WhatsApp Channel %s.", len(msgs), jidStr)
	// Replay oldest-first so posts thread in chronological order.
	for i := len(msgs) - 1; i >= 0; i-- {
		nm := msgs[i]
		if nm == nil || nm.Message == nil {
			continue
		}
		info := types.MessageInfo{
			MessageSource: types.MessageSource{
				Chat:    jid,
				Sender:  jid,
				IsGroup: false,
			},
			ID:        nm.MessageID,
			Timestamp: nm.Timestamp,
		}
		handler.handle_message(nm.Message, info, &events.Message{Info: info, Message: nm.Message})
	}
}
