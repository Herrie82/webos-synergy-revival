package main

/*
#include "bridge.h"
*/
import "C"

import (
	"context"
	"encoding/hex"
	"mime"
	"os"
	"path/filepath"
	"strings"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
)

func extension_from_mimetype(mimeType *string) string {
	extension := ".data"
	if mimeType != nil {
		// use the most poplular default for some common mimetypes
		if *mimeType == "image/jpeg" {
			return ".jpg"
		}
		if *mimeType == "image/png" {
			return ".png"
		}
		if *mimeType == "video/mp4" {
			return ".mp4"
		}
		// anything else is looked up
		extensions, _ := mime.ExtensionsByType(*mimeType)
		if extensions != nil {
			extension = extensions[0]
		}
	}
	return extension
}

// based on https://github.com/FKLC/WhatsAppToDiscord/blob/master/WA2DC.go
func (handler *Handler) handle_attachment(message *waE2E.Message, id string, source types.MessageSource, timestamp time.Time) {
	var (
		caption                                    = ""
		length       uint64                        = 0
		hash                                       = ""
		filename                                   = ""
		extension                                  = ""
		data_type    C.int                         = C.gowhatsapp_attachment_type_none
		downloadable whatsmeow.DownloadableMessage = nil
		mimetype                                   = ""
	)
	{
		im := message.GetImageMessage()
		if im != nil {
			downloadable = im
			hash = hex.EncodeToString(im.GetFileSHA256())
			extension = extension_from_mimetype(im.Mimetype)
			data_type = C.gowhatsapp_attachment_type_image
			mimetype = im.GetMimetype()
			length = im.GetFileLength()
			caption = im.GetCaption()
		}
	}
	{
		vm := message.GetVideoMessage()
		if vm != nil {
			downloadable = vm
			hash = hex.EncodeToString(vm.GetFileSHA256())
			extension = extension_from_mimetype(vm.Mimetype)
			data_type = C.gowhatsapp_attachment_type_video
			mimetype = vm.GetMimetype()
			length = vm.GetFileLength()
			caption = vm.GetCaption()
		}
	}
	{
		ptv := message.GetPtvMessage()
		if ptv != nil {
			downloadable = ptv
			hash = hex.EncodeToString(ptv.GetFileSHA256())
			extension = extension_from_mimetype(ptv.Mimetype)
			data_type = C.gowhatsapp_attachment_type_video
			mimetype = ptv.GetMimetype()
			length = ptv.GetFileLength()
			caption = ptv.GetCaption()
		}
	}
	{
		am := message.GetAudioMessage()
		if am != nil {
			downloadable = am
			hash = hex.EncodeToString(am.GetFileSHA256())
			extension = extension_from_mimetype(am.Mimetype)
			data_type = C.gowhatsapp_attachment_type_audio
			mimetype = am.GetMimetype()
			length = am.GetFileLength()
		}
	}
	{
		sm := message.GetStickerMessage()
		if sm != nil {
			downloadable = sm
			hash = hex.EncodeToString(sm.GetFileSHA256())
			extension = extension_from_mimetype(sm.Mimetype)
			data_type = C.gowhatsapp_attachment_type_sticker
			mimetype = sm.GetMimetype()
			length = sm.GetFileLength()
		}
	}
	{
		dm := message.GetDocumentMessage()
		if dm != nil {
			downloadable = dm
			hash = hex.EncodeToString(dm.GetFileSHA256())
			filename = dm.GetFileName() // TODO: sanitize filename
			extension = filepath.Ext(filename)
			if extension != "" {
				// remove extension from filename for consistency when using file-naming template
				filename = strings.TrimSuffix(filename, extension)
			} else {
				extension = extension_from_mimetype(dm.Mimetype)
			}
			data_type = C.gowhatsapp_attachment_type_document
			mimetype = dm.GetMimetype()
			length = dm.GetFileLength()
			caption = dm.GetCaption()
			// webOS: name the downloaded document by its REAL filename (not the content hash) so the
			// Messaging app's attachment chip shows e.g. "Q3-Report.pdf" instead of a hash / generic
			// label. The path template uses $hash, so put the sanitized real name there; keep the
			// content hash as a fallback when the document has no filename.
			if safe := sanitize_attachment_name(filename); safe != "" {
				hash = safe
			}
		}
	}
	if data_type != C.gowhatsapp_attachment_type_none {
		chat := source.Chat.ToNonAD().String()
		sender := source.Sender.ToNonAD().String()
		purple_handle_attachment(handler.account, chat, source.IsGroup, sender, caption, id, timestamp, data_type, filename, extension, mimetype, hash, length, downloadable)
	}
}

// sanitize_attachment_name makes a document's real filename safe to use as a single path component AND
// to survive the Messaging app's media-URL regex (which stops at whitespace): directory separators,
// control chars, spaces and characters that break a URL/path all map to "_".
func sanitize_attachment_name(name string) string {
	name = strings.TrimSpace(name)
	return strings.Map(func(r rune) rune {
		if r <= 0x20 || strings.ContainsRune("/\\?#\"'<>|:*&", r) {
			return '_'
		}
		return r
	}, name)
}

func (handler *Handler) download_attachment(local_file_path string, message whatsmeow.DownloadableMessage) error {
	os.MkdirAll(filepath.Dir(local_file_path), 0o755)
	// Download to memory then write the file ourselves. whatsmeow's DownloadToFile streams to an
	// *os.File and unconditionally calls fallocate(2), which webOS filesystems (tmpfs/vfat) reject
	// with EOPNOTSUPP; that gets misclassified as a network error, retried across hosts, and the
	// reused-but-not-truncated file corrupts the payload into an "invalid media hmac" failure.
	// The in-memory Download() path does io.ReadAll (no fallocate, no *os.File) and verifies the HMAC.
	data, err := handler.client.Download(context.TODO(), message)
	if err != nil {
		return err
	}
	if err := os.WriteFile(local_file_path, data, 0o644); err != nil {
		return err
	}
	// For videos, also drop the sender's embedded JPEG thumbnail next to the file as "<base>.jpg".
	// The Messaging app uses it as a <video poster> — a first-view preview that loads as a plain
	// image (independent of the clip's own data), which lets the player stay preload="none". The old
	// webOS WebKit can't paint a poster frame from an unplayed <video> otherwise, so without this the
	// preview box is black until the clip has been played once. Best-effort: a missing poster is fine.
	if vm, ok := message.(*waE2E.VideoMessage); ok {
		if thumb := vm.GetJPEGThumbnail(); len(thumb) > 0 {
			poster := strings.TrimSuffix(local_file_path, filepath.Ext(local_file_path)) + ".jpg"
			os.WriteFile(poster, thumb, 0o644)
		}
	}
	return nil
}
