package main

// call.go — WhatsApp voice calling, unified into the messaging plugin.
//
// Ported from the standalone `wacallm` mediator, but instead of opening its own
// whatsmeow session it attaches meowcaller to the plugin's EXISTING client
// (handler.client) — so there is ONE WhatsApp companion for both messaging and
// calling. One pairing (adding the account) enables both; the calling session can
// no longer get logged out independently, and it inherits the messaging session's
// own-LID (which meowcaller needs to place calls).
//
// The Go side owns the WhatsApp session + the VoIP engine (meowcaller); the C side
// (glue/call.c) owns the Luna bus (com.palm.whatsapp.call), the callStateQuery
// subscription, and the audiod PCM routing.
//
// C  -> Go (exported): gowhatsapp_go_call_dial / _answer / _hangup / _hangup_all
// Go -> C (glue/call.c): gowhatsapp_call_on_state(json), gowhatsapp_call_on_speaker(pcm,n),
//                        gowhatsapp_call_audio_active(on), gowhatsapp_call_read_mic(out,n)

/*
#include <stdlib.h>
// Implemented in glue/call.c:
extern void gowhatsapp_call_on_state(const char *json);      // full callStateQuery payload JSON
extern void gowhatsapp_call_on_speaker(const float *frame, int n); // received PCM -> speaker
extern void gowhatsapp_call_audio_active(int on);            // open/close ALSA playback+capture
extern int  gowhatsapp_call_read_mic(float *out, int n);    // Go pulls mic PCM from the C ring
*/
import "C"

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"runtime"
	"sync"
	"time"
	"unsafe"

	"github.com/purpshell/meowcaller"
	"go.mau.fi/whatsmeow/types"
)

const (
	callSampleRate   = meowcaller.SampleRate   // 16000
	callFrameSamples = meowcaller.FrameSamples // 960 (60ms)
)

type callInfo struct {
	c           *meowcaller.Call
	id          string
	address     string
	displayName string
	origin      string // "incoming" | "outgoing"
	state       string // dialing|incoming|active|onHold|disconnected
	incomingVid bool
	outgoingVid bool
	cause       string
	mic         *micSource
}

var (
	callCtx  = context.Background()
	mcClient *meowcaller.Client
	// The Handler that owns the whatsmeow client/store -- used to resolve an incoming caller's @lid
	// to their phone number (Store.LIDs) so the Phone app can match it to a contact. Set in startCalling.
	callHandler *Handler

	callMu  sync.Mutex
	calls   = map[string]*callInfo{} // id -> call
	dialing bool                     // an outgoing dial is in flight (guards double-dial)
)

// startCalling attaches meowcaller to the plugin's already-created whatsmeow client.
// MUST be called before client.Connect() so meowcaller's low-level <call> interception
// is installed before the receive loop starts (see meowcaller.NewClient docs).
func (handler *Handler) startCalling() {
	if mcClient != nil {
		// Only one calling engine is supported (single WhatsApp account). Re-linking
		// the same account replaces the engine so it tracks the live client.
		mcClient = nil
	}
	callHandler = handler
	// The MLow encoder runs inline in meowcaller's 60ms send-ticker; on the dual-core ARMv7 give the Go
	// runtime both cores so GC and the ALSA/network work overlap the encode instead of stealing from it.
	if runtime.GOMAXPROCS(0) < 2 {
		runtime.GOMAXPROCS(2)
	}
	mcClient = meowcaller.NewClient(handler.client)
	mcClient.OnIncomingCall(handleIncoming)
	fmt.Fprintln(os.Stderr, "wacall: calling engine attached to messaging session")
}

// ---- mic source: meowcaller PULLS frames via ReadFrame, which pulls PCM from the C
// mic ring buffer (gowhatsapp_call_read_mic). Pure Go->C on meowcaller's own thread. ----

type micSource struct{}

func newMicSource() *micSource { return &micSource{} }

func (m *micSource) ReadFrame() ([]float32, error) {
	f := make([]float32, callFrameSamples)
	C.gowhatsapp_call_read_mic((*C.float)(unsafe.Pointer(&f[0])), C.int(callFrameSamples))
	return f, nil
}

func (m *micSource) Close() error { return nil }

// ---- call-state payload pushed to Luna subscribers (CallSynergizer line/state shape) ----

func emitCallState() {
	type callJSON struct {
		ID            string `json:"id"`
		Address       string `json:"address"`
		DisplayName   string `json:"displayName"`
		Origin        string `json:"origin"`
		OnHold        bool   `json:"onHold"`
		IncomingVideo bool   `json:"incomingVideo"`
		OutgoingVideo bool   `json:"outgoingVideo"`
	}
	callMu.Lock()
	var cjs []callJSON
	lineState := ""
	cause := ""
	for _, ci := range calls {
		lineState = ci.state // single call per line: the line state IS the call state
		cause = ci.cause
		cjs = append(cjs, callJSON{
			ID: ci.id, Address: ci.address, DisplayName: ci.displayName,
			Origin: ci.origin, OnHold: ci.state == "onHold",
			IncomingVideo: ci.incomingVid, OutgoingVideo: ci.outgoingVid,
		})
	}
	callMu.Unlock()

	// CallSynergizer dispatches on the LINE-level "state" (handleActive/Incoming/
	// Disconnected) — NOT the call-level state — and logs disconnected lines.
	lines := []map[string]any{}
	if len(cjs) > 0 {
		line := map[string]any{"state": lineState, "calls": cjs}
		if lineState == "disconnected" {
			line["disconnectDetails"] = map[string]any{"cause": cause}
		}
		lines = append(lines, line)
	}
	payload := map[string]any{
		"returnValue":     true,
		"lines":           lines,
		"allowVideoCalls": true,
		"videoURI":        "",
	}
	b, _ := json.Marshal(payload)
	cs := C.CString(string(b))
	C.gowhatsapp_call_on_state(cs)
	C.free(unsafe.Pointer(cs))
}

// ---- wiring a *meowcaller.Call into our state + media ----

func wireCall(mcCall *meowcaller.Call, origin string, address string) *callInfo {
	ci := &callInfo{
		c:       mcCall,
		id:      mcCall.ID(),
		address: address,
		origin:  origin,
		mic:     newMicSource(),
	}
	if ci.address == "" {
		// Modern WhatsApp delivers an incoming caller as a @lid (an anonymised identity), NOT the phone
		// number -- so the Phone app can't match it to a contact and shows "Unknown Caller" + the raw
		// 14-digit LID. Resolve LID -> phone number via the same store the messaging side uses
		// (handler.lidToPn / Store.LIDs) and present it in the +E.164 form the WhatsApp contact records
		// are keyed on, so the caller's name resolves. Fall back to the raw id if unresolved.
		peer := mcCall.Peer()
		if callHandler != nil {
			peer = callHandler.lidToPn(peer, "incoming call peer")
		}
		if peer.Server == types.DefaultUserServer && peer.User != "" {
			ci.address = "+" + peer.User
		} else {
			ci.address = peer.User
		}
	}
	if origin == "incoming" {
		ci.state = "incoming"
	} else {
		ci.state = "dialing"
	}

	mcCall.OnPeerAccept(func() { setCallState(ci.id, "active", "") })
	mcCall.OnReady(func() { setCallState(ci.id, "active", "") })
	mcCall.OnEnd(func(reason string) { setCallState(ci.id, "disconnected", reason) })

	callMu.Lock()
	calls[ci.id] = ci
	callMu.Unlock()
	return ci
}

func setCallState(id, state, cause string) {
	callMu.Lock()
	if ci, ok := calls[id]; ok {
		ci.state = state
		if cause != "" {
			ci.cause = cause
		}
		if state == "disconnected" {
			if ci.mic != nil {
				ci.mic.Close()
			}
			C.gowhatsapp_call_audio_active(C.int(0)) // close ALSA playback + stop mic capture
			// keep the disconnected call briefly so CallSynergizer logs it, then drop
			go func(delID string) { time.Sleep(1500 * time.Millisecond); dropCall(delID) }(id)
		}
	}
	callMu.Unlock()
	emitCallState()
}

func dropCall(id string) {
	callMu.Lock()
	delete(calls, id)
	callMu.Unlock()
	emitCallState()
}

// attachMedia connects a call's mic source and speaker sink, and opens the ALSA
// playback+capture path so the call is audible on the loudspeaker.
func attachMedia(ci *callInfo) {
	C.gowhatsapp_call_audio_active(C.int(1)) // open playback + start mic capture -> read_mic
	ci.c.Play(ci.mic)
	ci.c.Receive(meowcaller.SinkFunc(func(frame []float32) {
		if len(frame) == 0 {
			return
		}
		C.gowhatsapp_call_on_speaker((*C.float)(unsafe.Pointer(&frame[0])), C.int(len(frame)))
	}))
}

func handleIncoming(mcCall *meowcaller.Call) {
	ci := wireCall(mcCall, "incoming", "")
	attachMedia(ci)
	emitCallState() // ring the UI
}

// ============================ exported C API ============================
//
// These are called on the luna-service mainloop thread, so they MUST NOT block.
// meowcaller Call/Answer/Hangup do network I/O, so we dispatch to a goroutine and
// return immediately. State (including the real call id) flows to the UI via the
// callStateQuery subscription.

//export gowhatsapp_go_call_dial
func gowhatsapp_go_call_dial(cAddr *C.char, video C.int) *C.char {
	addr := C.GoString(cAddr)
	if mcClient == nil {
		return C.CString("")
	}
	// Dedup: the phone-app dialer double-fires dial. Refuse a second dial while one
	// is already in flight or a call is live, so we don't place two calls.
	callMu.Lock()
	busy := dialing
	for _, c := range calls {
		if c.state != "disconnected" {
			busy = true
			break
		}
	}
	if busy {
		callMu.Unlock()
		fmt.Fprintln(os.Stderr, "wacall: dial ignored (already dialing/active)")
		return C.CString("ok")
	}
	dialing = true
	callMu.Unlock()
	v := video != 0
	go func() {
		defer func() {
			callMu.Lock()
			dialing = false
			callMu.Unlock()
		}()
		fmt.Fprintln(os.Stderr, "wacall: dialing", addr)
		mcCall, err := mcClient.Call(callCtx, addr)
		if err != nil {
			fmt.Fprintln(os.Stderr, "wacall: dial error:", err)
			return
		}
		ci := wireCall(mcCall, "outgoing", addr)
		ci.outgoingVid = v
		attachMedia(ci)
		if v {
			_ = mcCall.StartVideo()
		}
		emitCallState()
		fmt.Fprintln(os.Stderr, "wacall: call placed id", ci.id)
	}()
	return C.CString("ok") // ack; real id arrives via callStateQuery
}

//export gowhatsapp_go_call_answer
func gowhatsapp_go_call_answer(cID *C.char, video C.int) C.int {
	id := C.GoString(cID)
	v := video != 0
	go func() {
		callMu.Lock()
		ci := calls[id]
		callMu.Unlock()
		if ci == nil {
			return
		}
		if err := ci.c.Answer(); err != nil {
			fmt.Fprintln(os.Stderr, "wacall: answer error:", err)
			return
		}
		if v {
			_ = ci.c.AcceptVideo()
		}
		setCallState(id, "active", "")
	}()
	return 0
}

func hangupLive() {
	callMu.Lock()
	var live []*callInfo
	for _, c := range calls {
		if c.state != "disconnected" {
			live = append(live, c)
		}
	}
	callMu.Unlock()
	fmt.Fprintln(os.Stderr, "wacall: hangup all live:", len(live))
	for _, ci := range live {
		if ci.state == "incoming" {
			_ = ci.c.Reject()
		} else {
			_ = ci.c.Hangup()
		}
		setCallState(ci.id, "disconnected", "local")
	}
}

//export gowhatsapp_go_call_hangup_all
func gowhatsapp_go_call_hangup_all() C.int {
	go hangupLive()
	return 0
}

//export gowhatsapp_go_call_hangup
func gowhatsapp_go_call_hangup(cID *C.char) C.int {
	id := C.GoString(cID)
	go func() {
		callMu.Lock()
		ci := calls[id]
		callMu.Unlock()
		if ci == nil {
			// id didn't match (or empty) — the UI's id can lag; hang up all live.
			fmt.Fprintln(os.Stderr, "wacall: hangup id not found:", id, "-> hangup all")
			hangupLive()
			return
		}
		fmt.Fprintln(os.Stderr, "wacall: hangup id", id)
		if ci.state == "incoming" {
			_ = ci.c.Reject()
		} else {
			_ = ci.c.Hangup()
		}
		setCallState(id, "disconnected", "local")
	}()
	return 0
}
