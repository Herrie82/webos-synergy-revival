package main

/*
#include "bridge.h"
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"fmt"

	"github.com/rs/zerolog"
	"go.mau.fi/mautrix-meta/pkg/messagix"
)

// handlers maps a PurpleAccount to its live connection. All access is on libpurple's
// main thread (login/close/send are all called there), so no lock is needed here.
var handlers = make(map[*PurpleAccount]*Handler)

// Handler is one logged-in Facebook account.
type Handler struct {
	account  *PurpleAccount
	username string
	client   *messagix.Client
	logger   zerolog.Logger
	ctx      context.Context
	cancel   context.CancelFunc
}

// eventHandler receives messagix events (on Go goroutines) and translates the ones we
// support into purple. Anything touching purple goes through notify*/reportError, which
// marshal onto the main thread via the C glue.
func (h *Handler) eventHandler(ctx context.Context, rawEvt any) {
	switch evt := rawEvt.(type) {
	case *messagix.Event_Ready:
		h.logger.Info().Bool("new_session", evt.IsNewSession).Msg("connected (CONNACK)")
		h.notify(C.gometa_message_type_connected, "", "", 0)
	case *messagix.Event_Reconnected:
		h.notify(C.gometa_message_type_connected, "", "", 0)
	case *messagix.Event_SocketError:
		h.logger.Warn().Err(evt.Err).Int("attempts", evt.ConnectionAttempts).Msg("socket error")
	case *messagix.Event_PermanentError:
		h.notifyError(fmt.Sprintf("Facebook connection failed: %v", evt.Err), true)
	case *messagix.Event_PublishResponse:
		// TODO(increment 2): parse evt.Table (*table.LSTable) into incoming messages
		// (LSInsertMessage / LSUpsertMessage rows) and deliver via gometa_message_type_text.
		h.logger.Debug().Str("topic", evt.Topic).Msg("publish response (table parse TODO)")
	default:
		h.logger.Trace().Str("type", fmt.Sprintf("%T", rawEvt)).Msg("unhandled event")
	}
}

// sendMessage is invoked on a goroutine from gometa_go_send_message.
func (h *Handler) sendMessage(who, text string) {
	// TODO(increment 2): messagix task-based send for non-E2EE threads, and E2EE send
	// via client.PrepareE2EEClient()/whatsmeow after device registration (e2ee-register).
	h.logger.Warn().Str("to", who).Msg("send not implemented in this build")
	h.notifyError("Sending is not implemented yet in this build.", false)
}

// close disconnects and forgets the account (main thread).
func (h *Handler) close() {
	if h.cancel != nil {
		h.cancel()
	}
	if h.client != nil {
		h.client.Disconnect()
	}
	delete(handlers, h.account)
}

// notify pushes a state/message event to purple. C glue frees the strings.
func (h *Handler) notify(msgtype C.int, who, text string, ts int64) {
	msg := C.gometa_message_t{
		account:   h.account,
		msgtype:   C.char(msgtype),
		timestamp: C.time_t(ts),
	}
	if who != "" {
		msg.who = C.CString(who)
	}
	if text != "" {
		msg.text = C.CString(text)
	}
	C.gometa_process_message(msg)
}

func (h *Handler) notifyError(text string, fatal bool) {
	reportError(h.account, text, fatal)
}

// reportError works before a Handler exists (early login validation).
func reportError(account *PurpleAccount, text string, fatal bool) {
	msg := C.gometa_message_t{
		account: account,
		msgtype: C.char(C.gometa_message_type_error),
		text:    C.CString(text),
	}
	if fatal {
		msg.fatal = 1
	}
	C.gometa_process_message(msg)
}
