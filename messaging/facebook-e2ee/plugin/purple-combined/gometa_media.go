package main

// Facebook picture/attachment SEND. Plaintext threads: upload to Facebook's Mercury media endpoint
// and send a MEDIA task referencing the attachment fbid. Encrypted threads: upload+encrypt via
// whatsmeow and send an armadillo ImageMessage over the E2EE transport. Mirrors mautrix-meta's
// msgconv (SendMercuryUploadRequest / reuploadMediaToWhatsApp).

/*
#include <stdlib.h>
*/
import "C"

import (
	"bytes"
	"context"
	"fmt"
	"image"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"go.mau.fi/mautrix-meta/pkg/messagix/httpclient"
	"go.mau.fi/mautrix-meta/pkg/messagix/methods"
	"go.mau.fi/mautrix-meta/pkg/messagix/socket"
	"go.mau.fi/mautrix-meta/pkg/messagix/table"
	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waConsumerApplication"
	"go.mau.fi/whatsmeow/proto/waMediaTransport"
	"go.mau.fi/whatsmeow/proto/waMsgApplication"
	waTypes "go.mau.fi/whatsmeow/types"
	"google.golang.org/protobuf/proto"
)

//export gometa_go_send_file
// Send a local file to a thread. Returns "" on success or an error string (freed by the C caller).
func gometa_go_send_file(account *PurpleAccount, who *C.char, filename *C.char) *C.char {
	h, ok := gometaHandlers[account]
	if !ok {
		return C.CString("Facebook connection not found")
	}
	if err := h.sendFile(C.GoString(who), C.GoString(filename)); err != nil {
		h.logger.Warn().Err(err).Msg("send file failed")
		return C.CString(err.Error())
	}
	return C.CString("")
}

func (h *gometaHandler) sendFile(who, filename string) error {
	threadID, err := strconv.ParseInt(who, 10, 64)
	if err != nil {
		return fmt.Errorf("invalid recipient %q", who)
	}
	if h.client == nil {
		return fmt.Errorf("Facebook not connected")
	}
	data, err := os.ReadFile(filename)
	if err != nil {
		return fmt.Errorf("read %s: %w", filename, err)
	}
	mime := http.DetectContentType(data)
	isImage := strings.HasPrefix(mime, "image/")

	h.mu.Lock()
	isE2EE := h.e2eeContacts[threadID]
	h.mu.Unlock()
	if isE2EE {
		if h.e2ee == nil {
			return fmt.Errorf("encrypted thread and E2EE isn't connected yet")
		}
		if !isImage {
			return fmt.Errorf("only images can be sent to encrypted threads for now")
		}
		return h.sendImageE2EE(threadID, data, mime)
	}
	return h.sendMediaPlaintext(threadID, data, filepath.Base(filename), mime)
}

// sendMediaPlaintext uploads to Facebook and sends a MEDIA task. If Facebook doesn't confirm the
// send (the E2EE-thread rejection), it auto-retries the image over the encrypted transport.
func (h *gometaHandler) sendMediaPlaintext(threadID int64, data []byte, filename, mime string) error {
	ctx, cancel := context.WithTimeout(h.ctx, 120*time.Second)
	defer cancel()
	if err := h.client.WaitUntilCanSendMessages(ctx, 20*time.Second); err != nil {
		return err
	}
	resp, err := h.client.GetHTTP().SendMercuryUploadRequest(ctx, threadID, &httpclient.MercuryUploadMedia{
		Filename:  filename,
		MimeType:  mime,
		MediaData: data,
	})
	if err != nil {
		return fmt.Errorf("upload: %w", err)
	}
	attachmentID := resp.Payload.RealMetadata.GetFbId()
	if attachmentID == 0 {
		return fmt.Errorf("upload returned no attachment id")
	}
	otid := methods.GenerateEpochID()
	h.mu.Lock()
	h.sentOtids[otid] = true
	h.mu.Unlock()
	task := &socket.SendMessageTask{
		ThreadId:         threadID,
		Otid:             otid,
		Source:           table.MESSENGER_INBOX_IN_THREAD,
		InitiatingSource: table.FACEBOOK_INBOX,
		SendType:         table.MEDIA,
		SyncGroup:        1,
		AttachmentFBIds:  []int64{attachmentID},
	}
	sendResp, err := h.client.ExecuteTasks(ctx, task)
	if err != nil {
		return err
	}
	otidStr := strconv.FormatInt(otid, 10)
	if sendResp != nil {
		for _, r := range sendResp.LSReplaceOptimsiticMessage {
			if r.OfflineThreadingId == otidStr {
				h.logger.Info().Int64("thread", threadID).Msg("media sent")
				return nil
			}
		}
	}
	// Not confirmed — likely an encrypted thread. Retry the image over E2EE and remember it.
	h.mu.Lock()
	delete(h.sentOtids, otid)
	h.mu.Unlock()
	if h.e2ee != nil && strings.HasPrefix(mime, "image/") {
		h.mu.Lock()
		h.e2eeContacts[threadID] = true
		h.mu.Unlock()
		h.logger.Warn().Int64("thread", threadID).Msg("media send not confirmed; retrying over E2EE")
		return h.sendImageE2EE(threadID, data, mime)
	}
	return fmt.Errorf("send not confirmed (thread may be encrypted)")
}

// sendImageE2EE uploads+encrypts an image via whatsmeow and sends it over the E2EE transport.
func (h *gometaHandler) sendImageE2EE(threadID int64, data []byte, mime string) error {
	ctx, cancel := context.WithTimeout(h.ctx, 120*time.Second)
	defer cancel()
	uploaded, err := h.e2ee.Upload(ctx, data, whatsmeow.MediaImage)
	if err != nil {
		return fmt.Errorf("e2ee upload: %w", err)
	}
	w, ht := imageDims(data)
	mediaTransport := &waMediaTransport.WAMediaTransport{
		Integral: &waMediaTransport.WAMediaTransport_Integral{
			FileSHA256:        uploaded.FileSHA256,
			MediaKey:          uploaded.MediaKey,
			FileEncSHA256:     uploaded.FileEncSHA256,
			DirectPath:        &uploaded.DirectPath,
			MediaKeyTimestamp: proto.Int64(time.Now().Unix()),
		},
		Ancillary: &waMediaTransport.WAMediaTransport_Ancillary{
			FileLength: proto.Uint64(uint64(len(data))),
			Mimetype:   &mime,
			// Messenger iOS/Android refuse to render media without a thumbnail w/h.
			Thumbnail: &waMediaTransport.WAMediaTransport_Ancillary_Thumbnail{
				ThumbnailWidth:  proto.Uint32(uint32(w)),
				ThumbnailHeight: proto.Uint32(uint32(ht)),
			},
			ObjectID: &uploaded.ObjectID,
		},
	}
	imageMsg := &waConsumerApplication.ConsumerApplication_ImageMessage{}
	if err := imageMsg.Set(&waMediaTransport.ImageTransport{
		Integral: &waMediaTransport.ImageTransport_Integral{Transport: mediaTransport},
		Ancillary: &waMediaTransport.ImageTransport_Ancillary{
			Height: proto.Uint32(uint32(ht)),
			Width:  proto.Uint32(uint32(w)),
		},
	}); err != nil {
		return fmt.Errorf("build image message: %w", err)
	}
	msg := &waConsumerApplication.ConsumerApplication{
		Payload: &waConsumerApplication.ConsumerApplication_Payload{
			Payload: &waConsumerApplication.ConsumerApplication_Payload_Content{
				Content: &waConsumerApplication.ConsumerApplication_Content{
					Content: &waConsumerApplication.ConsumerApplication_Content_ImageMessage{ImageMessage: imageMsg},
				},
			},
		},
	}
	otid := methods.GenerateEpochID()
	h.mu.Lock()
	h.sentOtids[otid] = true
	h.mu.Unlock()
	to := waTypes.JID{User: strconv.FormatInt(threadID, 10), Server: waTypes.MessengerServer}
	if _, err := h.e2ee.SendFBMessage(ctx, to, msg, &waMsgApplication.MessageApplication_Metadata{},
		whatsmeow.SendRequestExtra{ID: waTypes.MessageID(strconv.FormatInt(otid, 10))}); err != nil {
		return fmt.Errorf("e2ee image send: %w", err)
	}
	h.logger.Info().Int64("thread", threadID).Msg("e2ee image sent")
	return nil
}

// imageDims returns the image dimensions, or 400x400 if they can't be decoded (Messenger requires
// non-zero width/height on media).
func imageDims(data []byte) (int, int) {
	cfg, _, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil || cfg.Width == 0 || cfg.Height == 0 {
		return 400, 400
	}
	return cfg.Width, cfg.Height
}
