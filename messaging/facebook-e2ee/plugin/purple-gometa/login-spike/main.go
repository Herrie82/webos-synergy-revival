// Command login-spike drives mautrix-meta's messagix client DIRECTLY (no Matrix
// bridge) to retire two risks before we invest in prpl glue:
//
//  1. Is messagix usable as a standalone library? (mautrix/meta#104 says it's
//     somewhat bridge-coupled.) If this program logs in, loads the inbox and
//     connects using only the messagix + cookies packages, the answer is yes.
//  2. What is the login/session surface? messagix authenticates with Facebook
//     *cookies* (not username/password) — c_user, xs, datr at minimum. This maps
//     exactly what the webOS account-setup app will have to collect.
//
// It also confirms the E2EE transport can be prepared (PrepareE2EEClient returns a
// *whatsmeow.Client — Messenger E2EE rides WhatsApp's Signal infrastructure).
//
// Run it on the host first (fast iteration, has network):
//
//	go run ./login-spike cookies.json
//	# or: META_COOKIES=cookies.json go run ./login-spike
//
// cookies.json is a flat object of Facebook cookie name -> value, copied from a
// logged-in browser session (DevTools > Application > Cookies on facebook.com):
//
//	{"c_user":"100...","xs":"...","datr":"...","sb":"...","fr":"...","wd":"1920x1080"}
//
// The same source cross-compiles for armv7 (spike already proved messagix builds
// GOARM=7, pure-Go and c-archive) — that path is exercised by build-meta.sh later.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/signal"
	"reflect"
	"syscall"
	"time"

	"github.com/rs/zerolog"
	"go.mau.fi/mautrix-meta/pkg/messagix"
	"go.mau.fi/mautrix-meta/pkg/messagix/cookies"
	"go.mau.fi/mautrix-meta/pkg/messagix/types"
)

func main() {
	path := os.Getenv("META_COOKIES")
	if len(os.Args) > 1 {
		path = os.Args[1]
	}
	if path == "" {
		fmt.Fprintln(os.Stderr, "usage: login-spike <cookies.json>   (or META_COOKIES=<path>)")
		fmt.Fprintln(os.Stderr, `cookies.json = {"c_user":"...","xs":"...","datr":"...","sb":"...","fr":"..."}`)
		os.Exit(2)
	}

	// --- Stage 1: load cookies (the auth material) -------------------------
	raw, err := os.ReadFile(path)
	if err != nil {
		fatal("read cookies %q: %v", path, err)
	}
	var kv map[string]string
	if err := json.Unmarshal(raw, &kv); err != nil {
		fatal("parse cookies (want a flat {\"name\":\"value\"} object): %v", err)
	}
	ck := &cookies.Cookies{Platform: types.Facebook} // FB Messenger via facebook.com
	conv := make(map[cookies.MetaCookieName]string, len(kv))
	for k, v := range kv {
		conv[cookies.MetaCookieName(k)] = v
	}
	ck.UpdateValues(conv)
	if !ck.IsLoggedIn() {
		fatal("cookies missing required fields %v (need at least c_user, xs, datr)", ck.GetMissingCookieNames())
	}
	fmt.Printf("[spike] 1/5 cookies OK — user_id=%d, %d cookies\n", ck.GetUserID(), len(conv))

	logger := zerolog.New(zerolog.ConsoleWriter{Out: os.Stderr, TimeFormat: time.Kitchen}).
		With().Timestamp().Logger()
	cli := messagix.NewClient(ck, logger, &messagix.Config{})

	// Log the concrete Go type of every event — this enumerates the event surface
	// the prpl glue will have to translate into libpurple callbacks.
	seen := map[string]int{}
	total := 0
	cli.SetEventHandler(func(ctx context.Context, evt any) {
		total++
		t := reflect.TypeOf(evt).String()
		seen[t]++
		if seen[t] <= 2 { // print first couple of each type, then stay quiet
			fmt.Printf("[spike] event: %s\n", t)
		}
	})

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// --- Stage 2: LoadMessagesPage = authenticate + fetch inbox snapshot ---
	fmt.Println("[spike] 2/5 LoadMessagesPage (auth + inbox)...")
	loadCtx, loadCancel := context.WithTimeout(ctx, 90*time.Second)
	user, tbl, err := cli.LoadMessagesPage(loadCtx)
	loadCancel()
	if err != nil {
		fatal("LoadMessagesPage failed (auth/checkpoint/protocol): %v", err)
	}
	fmt.Printf("[spike]     AUTH OK — account=%q authenticated=%v\n", user.GetName(), cli.IsAuthenticated())
	if tbl != nil {
		fmt.Println("[spike]     initial inbox LSTable received")
	}

	// --- Stage 3: Connect the realtime (lightspeed) socket -----------------
	fmt.Println("[spike] 3/5 Connect (lightspeed socket)...")
	if err := cli.Connect(ctx); err != nil {
		fatal("Connect failed: %v", err)
	}
	fmt.Printf("[spike]     connected=%v\n", cli.IsConnected())

	// --- Stage 4: wait until the client is allowed to send -----------------
	fmt.Println("[spike] 4/5 WaitUntilCanSendMessages (<=60s)...")
	if err := cli.WaitUntilCanSendMessages(ctx, 60*time.Second); err != nil {
		fmt.Printf("[spike]     WARN not send-ready: %v\n", err)
	} else {
		fmt.Println("[spike]     SEND-READY")
	}

	// --- Stage 5: prove the E2EE (whatsmeow) transport can be prepared -----
	fmt.Println("[spike] 5/5 PrepareE2EEClient (Messenger E2EE via whatsmeow)...")
	if wa, err := cli.PrepareE2EEClient(); err != nil {
		fmt.Printf("[spike]     PrepareE2EEClient err (may need device registration first): %v\n", err)
	} else if wa != nil {
		fmt.Println("[spike]     E2EE whatsmeow client prepared")
	}

	fmt.Println("[spike] listening 45s for realtime events (Ctrl-C to stop)...")
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	select {
	case <-time.After(45 * time.Second):
	case <-sig:
	}

	cli.Disconnect()
	fmt.Printf("[spike] done. distinct_event_types=%d total_events=%d\n", len(seen), total)
	for t, n := range seen {
		fmt.Printf("[spike]   %3d x %s\n", n, t)
	}
}

func fatal(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "[spike] FATAL: "+format+"\n", a...)
	os.Exit(1)
}
