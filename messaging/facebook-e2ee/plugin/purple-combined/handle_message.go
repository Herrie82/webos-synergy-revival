package main

/*
#include "constants.h"
*/
import "C"

import (
	"context"
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
)

func GetAnyPollCreationMessage(message *waE2E.Message) *waE2E.PollCreationMessage {
	if message.PollCreationMessageV5 != nil {
		return message.PollCreationMessageV5
	}
	if message.PollCreationMessageV3 != nil {
		return message.PollCreationMessageV3
	}
	if message.PollCreationMessageV2 != nil {
		return message.PollCreationMessageV2
	}
	if message.PollCreationMessage != nil {
		return message.PollCreationMessage
	}
	return nil
}

// write_link_preview_thumbnail persists an ExtendedTextMessage's inline link-preview JPEG thumbnail
// to the account's attachment directory and returns a file:// URL for it (or "" on failure / when the
// attachment path isn't configured). The directory is the static prefix of the account's
// attachment-path-template (everything before the first "$" placeholder) - the same dir real
// downloaded attachments land in - so the Messaging app can load it as an inline <img>. The file is
// named by a content hash so an identical thumbnail is written once and re-render is idempotent.
func (handler *Handler) write_link_preview_thumbnail(data []byte) string {
	tmpl := purple_get_string(handler.account, C.GOWHATSAPP_ATTACHMENT_PATH_TEMPLATE_OPTION, C.GOWHATSAPP_ATTACHMENT_PATH_TEMPLATE_DEFAULT)
	prefix := strings.SplitN(tmpl, "$", 2)[0]
	if prefix == "" {
		return "" // no attachment path configured (or template starts with a placeholder) - skip
	}
	dir := filepath.Dir(prefix + "x") // keep the full directory even when the prefix ends in "/"
	if !filepath.IsAbs(dir) {
		return ""
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return ""
	}
	sum := sha256.Sum256(data)
	local := filepath.Join(dir, fmt.Sprintf("linkpreview_%x.jpg", sum[:16]))
	if err := os.WriteFile(local, data, 0o644); err != nil {
		return ""
	}
	return "file://" + local
}

func (handler *Handler) handle_message(message *waE2E.Message, info types.MessageInfo, evt *events.Message) {
	//handler.log.Infof("message: %#v", message)
	if message.SenderKeyDistributionMessage != nil {
		// Apparently, a SenderKeyDistributionMessage can share the a message ID with a conversation message which is to arrive later
		// I do not need this message type in the front-end, so I rather drop it
		// This should be safe (as in "will not inadvertedly drop message with actual payload") since all …Messsage fields seem to be mutually exclusive
		handler.log.Infof("Ignoring SenderKeyDistributionMessage.")
		return
	}
	text := ""
	if info.MessageSource.Chat == types.StatusBroadcastJID {
		if purple_get_bool(handler.account, C.GOWHATSAPP_IGNORE_STATUS_BROADCAST_OPTION, false) {
			// some people find status broadcasts annoying
			handler.log.Warnf("Ignoring status broadcast.")
			return
		} else {
			// the protocol implements status broadcasts in the form of a group
			// we just treat those messages as if they were direct messages
			info.MessageSource.Chat = info.MessageSource.Sender
			info.MessageSource.IsGroup = false
			text = "[STATUS] "
		}
	}
	if handler.blocklist != nil {
		// TODO find out whether locally checking the blocklist is actually necessary or if WhatsApp servers do the filtering for us
		for _, blockedJID := range handler.blocklist.JIDs {
			if blockedJID.ToNonAD() == info.MessageSource.Sender.ToNonAD() {
				handler.log.Infof("Ignoring message from %s since they are on the blocklist.", info.MessageSource.Sender.ToNonAD().String())
			}
		}
	}
	info.MessageSource.Chat = handler.lidToPn(info.MessageSource.Chat, "handling message chat")
	info.MessageSource.Sender = handler.lidToPn(info.MessageSource.Sender, "handling message sender")
	// Dedup WhatsApp Channel (newsletter) posts: they reach us TWICE - whatsmeow offline-syncs recent
	// posts as live messages on connect, AND fetch_newsletter_history replays the last 50 when the
	// channel is opened in the Servers tab. The WhatsApp message id is stable across both paths, so
	// skip a post we've already delivered (otherwise every channel post shows up doubled). The seen set
	// is loaded at login and saved on close (newsletter_seen.go), so a reopen next session won't re-dup.
	if info.MessageSource.Chat.Server == types.NewsletterServer && handler.newsletterAlreadySeen(info.ID) {
		return
	}
	isEdit := false
	{
		if pm := message.GetProtocolMessage(); pm != nil {
			if em := pm.GetEditedMessage(); em != nil {
				message = em
				isEdit = true
			}
		}
	}
	text += message.GetConversation()
	var quotedText, quotedFrom, quotedId string
	{
		etm := message.ExtendedTextMessage
		if etm != nil {
			// message containing quote or link to group
			// link messages have message.Conversation set to nil anyway
			// it should be safe to overwrite here
			// webOS replies: capture the quoted-original as STRUCTURED data (author/text/StanzaID) so the
			// transport renders an inline quote card, instead of folding "> ..." into the message body.
			ci := etm.ContextInfo
			if ci != nil {
				cm := ci.QuotedMessage
				if cm != nil {
					quotedId = ci.GetStanzaID()
					if p := ci.GetParticipant(); p != "" {
						if pjid, err := types.ParseJID(p); err == nil {
							quotedFrom = purple_get_alias(handler.account, handler.lidToPn(pjid, "resolving quote author").ToNonAD().String())
						}
					}
					qt := cm.GetConversation()
					if qt == "" {
						qt = cm.GetExtendedTextMessage().GetText()
					}
					quotedText = strings.ReplaceAll(strings.ReplaceAll(qt, "\r", " "), "\n", " ")
				}
			}
			if etm.Text != nil {
				etmText := *etm.Text
				for _, mentioned := range etm.GetContextInfo().GetMentionedJID() {
					mentionedJID, err := types.ParseJID(mentioned)
					if err == nil {
						alias := purple_get_alias(handler.account, handler.lidToPn(mentionedJID, "resolving mention").ToNonAD().String())
						etmText = strings.ReplaceAll(etmText, mentionedJID.User, alias)
					}
				}
				text += etmText
			}
			// webOS: WhatsApp link-preview posts (news channels like BBC News / Dumpert) arrive as an
			// ExtendedTextMessage with a URL preview - an inline JPEG thumbnail + a title - NOT an image
			// attachment, so previously only the raw body text showed. Prepend the preview card: the
			// thumbnail (written to the attachment dir, referenced as a file:// URL the app renders
			// inline) then the title, above the body. GetJPEGThumbnail/GetTitle are empty for
			// plain/quoted ExtendedTextMessages, so this only fires for actual link previews.
			{
				preview := ""
				if thumb := etm.GetJPEGThumbnail(); len(thumb) > 0 {
					preview = handler.write_link_preview_thumbnail(thumb)
				}
				if title := etm.GetTitle(); title != "" {
					if preview != "" {
						preview += "\n"
					}
					preview += title
				}
				if desc := etm.GetDescription(); desc != "" {
					if preview != "" {
						preview += "\n"
					}
					preview += desc
				}
				if preview != "" {
					text = preview + "\n" + text
				}
			}
		}

	}
	{
		rm := message.GetReactionMessage()
		if rm != nil && rm.Text != nil && rm.Key != nil && rm.Key.ID != nil {
			// webOS reactions: attach to the target message via the transport's reaction signal
			// instead of posting a "reacted with X" message. rm.Key.ID = the reacted-to message id,
			// rm.Text = the emoji ("" means the reaction was removed), Sender = who reacted. Return
			// early: a ReactionMessage carries nothing else to display.
			chat := info.MessageSource.Chat.ToNonAD().String()
			sender := info.MessageSource.Sender.ToNonAD().String()
			purple_handle_reaction(handler.account, chat, rm.Key.GetID(), rm.GetText(), sender)
			return
		}
	}
	{
		pcm := GetAnyPollCreationMessage(message)
		if pcm != nil {
			//handler.log.Infof("message poll creation: %#v", pcm)
			text = fmt.Sprintf("[POLL] %s\n", pcm.GetName())
			for i, option := range pcm.GetOptions() {
				if option.OptionHash == nil {
					// taken from whatsmeow.HashPollOptions()
					hash := fmt.Sprintf("%X", sha256.Sum256([]byte(option.GetOptionName())))
					option.OptionHash = &hash
				}
				text += fmt.Sprintf("%d: %s\n", i+1, option.GetOptionName())
				//handler.log.Infof("message poll creation option #%d: %#v", i, option)
			}
			selectable_options := pcm.GetSelectableOptionsCount()
			switch selectable_options {
			case 0:
				text += "One may chose multiple answers."
			case 1:
				text += "One may chose one answer."
			default:
				text += fmt.Sprintf("One may chose up to %d answers.", selectable_options)
			}
		}
	}
	{
		pum := message.GetPollUpdateMessage()
		if pum != nil {
			cached_message := handler.lookup_cached_message_by_id(pum.GetPollCreationMessageKey().GetID())
			if cached_message == nil {
				text = "voted in a poll, but this plug-in failed to keep track of the poll."
			} else {
				decrypted, err := handler.client.DecryptPollVote(context.TODO(), evt)
				if err != nil {
					handler.log.Warnf("Failed to decrypt poll vote: %v", err)
				} else {
					pcm := GetAnyPollCreationMessage(&cached_message.Message)
					text = fmt.Sprintf("voted in poll „%s“ for", pcm.GetName())
					if len(decrypted.SelectedOptions) == 0 {
						text += " nothing (removed vote)"
					} else {
						for index, option_hash := range decrypted.SelectedOptions {
							hash := fmt.Sprintf("%X", option_hash)
							var option_name *string = nil
							for _, option := range pcm.Options {
								if option.GetOptionHash() == hash {
									option_name = option.OptionName
								}
							}
							if option_name == nil {
								handler.log.Warnf("Failed look-up poll vote option %s in %#v", hash, &cached_message.Message)
								text += " an unknown option"
							} else {
								separator := ""
								if len(decrypted.SelectedOptions) > 1 {
									if index > 0 {
										separator = ","
									}
									if index == len(decrypted.SelectedOptions)-1 {
										separator = " and"
									}
								}
								text += fmt.Sprintf("%s „%s“", separator, *option_name)
							}
						}
					}
					text += "."
				}
			}
		}
	}
	if text != "" {
		if isEdit {
			text = "[EDIT] " + text
		}
		// note: info.PushName always denotes the sender (not the chat)
		purple_display_text_message(handler.account, info.MessageSource.Chat.ToNonAD().String(), info.MessageSource.IsGroup, false, info.MessageSource.Sender.ToNonAD().String(), &info.PushName, info.Timestamp, text, &info.ID, quotedText, quotedFrom, quotedId)
	}
	if !isEdit { // edited messages contain the changed texts, but attachments are absent since they cannot be changed
		handler.handle_attachment(message, info.ID, info.MessageSource, info.Timestamp)
	}
	handler.add_to_cache(message, info.ID, info.MessageSource.Chat, info.MessageSource.Sender, info.Timestamp)
}
