#!/bin/sh
# Deploy the contacts.plugin.messaging BIG-HACK guard to the on-device linker plugin (stock Palm
# framework, not vendored). The linker calls this plugin's personChanged() for every person it
# re-saves during a re-link; the stock code's "BIG HACK" then re-runs the FULL personAdded()
# messaging association even when nothing changed -- pure waste for already-associated contacts
# (~350ms/contact). The guard skips personAdded when a chatthread/imbuddystatus record already
# carries this person's personId (proof of a prior association); genuinely-new persons still
# associate. See README.md for the on-device A/B numbers.
#
# Idempotent; backs up the original to personChanged.js.b4bighackguard. Run over novacom:
#   novacom -d topaz-linux run file:///bin/sh -- < install.sh
# (or push this dir and run ./install.sh on the device).
set -e
J=/usr/palm/frameworks/contacts.plugin.messaging/submission/12.1/javascript
HERE=$(dirname "$0")
mount -o remount,rw / 2>/dev/null || true

# NOTE: the linker loads the plugin from the manifest's javascript/ source files (debug mode),
# NOT the built submission/12.1contacts_plugin_messaging.js -- so patch the source file.
[ -f "$J/personChanged.js.b4bighackguard" ] || cp "$J/personChanged.js" "$J/personChanged.js.b4bighackguard"
cp "$HERE/personChanged.js" "$J/personChanged.js"

# The linker caches the plugin in-process, so kill it to force a reload on the next autolink.
for p in /proc/[0-9]*; do
	grep -qa "contacts.linker" "$p/cmdline" 2>/dev/null && kill "${p##*/}" 2>/dev/null || true
done

echo "installed guard: alreadyAssociated markers in personChanged.js = $(grep -c alreadyAssociated "$J/personChanged.js")"
echo "backup at $J/personChanged.js.b4bighackguard"
echo "linker killed; guard loads on the next autolink run (forceAutolink or a contact change)."

# To revert:
#   cp $J/personChanged.js.b4bighackguard $J/personChanged.js  (then kill the linker as above)
