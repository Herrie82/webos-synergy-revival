package main

/*
#include "bridge.h"
*/
import "C"

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"time"

	"github.com/rs/zerolog"
	"go.mau.fi/mautrix-meta/pkg/messagix"
	"go.mau.fi/mautrix-meta/pkg/messagix/cookies"
	"go.mau.fi/mautrix-meta/pkg/messagix/types"
)

// login is the Go side of purple's login(). Runs on the main thread; the blocking
// network work (auth + connect) is done on a goroutine so purple stays responsive.
//
// `cookieJSON` is the account password: a JSON object of Facebook cookie name -> value
// copied from a logged-in browser (c_user, xs, datr required).
func login(account *PurpleAccount, purpleUserDir, username, cookieJSON, proxy string) {
	if _, ok := handlers[account]; ok {
		reportError(account, "This connection already exists.", true)
		return
	}

	logger := zerolog.New(zerolog.ConsoleWriter{Out: os.Stderr, TimeFormat: time.Kitchen}).
		With().Str("account", username).Timestamp().Logger()

	var kv map[string]string
	if err := json.Unmarshal([]byte(cookieJSON), &kv); err != nil {
		reportError(account, "Facebook cookies are not valid JSON. Paste the cookie JSON as the password.", true)
		return
	}
	ck := &cookies.Cookies{Platform: types.Facebook}
	conv := make(map[cookies.MetaCookieName]string, len(kv))
	for k, v := range kv {
		conv[cookies.MetaCookieName(k)] = v
	}
	ck.UpdateValues(conv)
	if !ck.IsLoggedIn() {
		reportError(account, fmt.Sprintf("Facebook cookies missing required fields: %v", ck.GetMissingCookieNames()), true)
		return
	}

	client := messagix.NewClient(ck, logger, &messagix.Config{})
	ctx, cancel := context.WithCancel(context.Background())
	h := &Handler{
		account:  account,
		username: username,
		client:   client,
		logger:   logger,
		ctx:      ctx,
		cancel:   cancel,
	}
	handlers[account] = h
	client.SetEventHandler(h.eventHandler)

	go func() {
		loadCtx, loadCancel := context.WithTimeout(ctx, 90*time.Second)
		user, _, err := client.LoadMessagesPage(loadCtx)
		loadCancel()
		if err != nil {
			h.notifyError(fmt.Sprintf("Facebook login failed: %v", err), true)
			return
		}
		h.logger.Info().Str("name", user.GetName()).Msg("authenticated")
		if err := client.Connect(ctx); err != nil {
			h.notifyError(fmt.Sprintf("Facebook connect failed: %v", err), true)
		}
	}()
}
