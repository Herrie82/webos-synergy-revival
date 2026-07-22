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
		// Strip any parameters, e.g. voice notes arrive as "audio/ogg; codecs=opus".
		base := strings.TrimSpace(strings.SplitN(*mimeType, ";", 2)[0])
		// Stable defaults for the common WhatsApp media types. Explicit cases matter for audio:
		// voice notes are "audio/ogg; codecs=opus" and without this fell through to
		// mime.ExtensionsByType (which has no audio/ogg entry in the device mime db) and got
		// ".data" - an extension no app can open. ".ogg" is the correct container (Opus-in-Ogg),
		// and Atlas registers .ogg + bundles the opus/ogg codecs to play it.
		switch base {
		case "image/jpeg":
			return ".jpg"
		case "image/png":
			return ".png"
		case "image/gif":
			return ".gif"
		case "image/webp":
			return ".webp"
		case "video/mp4":
			return ".mp4"
		case "video/3gpp":
			return ".3gp"
		case "audio/ogg", "application/ogg":
			return ".ogg"
		case "audio/mpeg", "audio/mp3":
			return ".mp3"
		case "audio/mp4", "audio/aac", "audio/x-m4a":
			return ".m4a"
		case "audio/amr":
			return ".amr"
		case "audio/wav", "audio/x-wav":
			return ".wav"
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
		}
	}
	if data_type != C.gowhatsapp_attachment_type_none {
		chat := source.Chat.ToNonAD().String()
		sender := source.Sender.ToNonAD().String()
		purple_handle_attachment(handler.account, chat, source.IsGroup, sender, caption, id, timestamp, data_type, filename, extension, mimetype, hash, length, downloadable)
	}
}

func (handler *Handler) download_attachment(local_file_path string, message whatsmeow.DownloadableMessage) error {
	os.MkdirAll(filepath.Dir(local_file_path), 0o755)
	file, err := os.Create(local_file_path)
	if err != nil {
		return err
	}
	return handler.client.DownloadToFile(context.TODO(), message, file)
}
