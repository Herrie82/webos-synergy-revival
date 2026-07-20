// purple-gometa: a libpurple protocol plugin for Facebook Messenger (incl. E2EE),
// wrapping mautrix-meta's messagix Go library. Mirrors the WhatsApp plugin
// (../../../whatsapp/plugin/purple-gowhatsapp): a Go c-archive of //export'd
// callbacks, linked against C glue that registers the prpl with libpurple.
//
// Package must be `main` for buildmode=c-archive even though it is a library.
package main

/*
#include "constants.h"
#include "bridge.h"
*/
import "C"

type PurpleAccount = C.PurpleAccount

// main is required for a c-archive build but is never called.
func main() {}

//export gometa_go_login
// Called from purple's login(). `cookies` is the account password: a JSON object of
// Facebook cookie name -> value (c_user, xs, datr required).
func gometa_go_login(account *PurpleAccount, purpleUserDir *C.char, username *C.char, cookies *C.char, proxy *C.char) {
	login(account, C.GoString(purpleUserDir), C.GoString(username), C.GoString(cookies), C.GoString(proxy))
}

//export gometa_go_close
// Called from purple's close(): disconnect and forget the account.
func gometa_go_close(account *PurpleAccount) {
	if h, ok := handlers[account]; ok {
		h.close()
	}
}

//export gometa_go_send_message
// Called from purple's send_im(). Returns 1 if accepted, 0 if not connected.
func gometa_go_send_message(account *PurpleAccount, who *C.char, message *C.char) C.int {
	h, ok := handlers[account]
	if !ok {
		return 0
	}
	go h.sendMessage(C.GoString(who), C.GoString(message))
	return 1
}
