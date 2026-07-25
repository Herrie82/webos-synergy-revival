#!/bin/bash
# The WhatsApp prpl is no longer a standalone plugin. It was consolidated into the COMBINED plugin
# (messaging/facebook-e2ee/plugin/purple-combined): ONE libwhatsmeow.so hosts BOTH prpl-hehoe-whatsmeow
# and prpl-gometa, plus WhatsApp send-reaction, Channels/newsletters, and calling (meowcaller +
# glue/call.c com.palm.whatsapp.call LS2 service). The old standalone purple-gowhatsapp was removed.
#
# This wrapper builds the combined plugin so anything that used to call build-whatsapp.sh still works.
set -e
exec "$(dirname "$0")/../facebook-e2ee/plugin/purple-combined/build-combined.sh" "$@"
