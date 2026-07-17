#!/bin/bash
# webOS (LunaCE/TouchPad) font fallback fix — render Thai in the UI (contact/channel names etc.).
#
# WHY: libWebKitLuna does NOT use fontconfig or CSS font-family fallback. It uses a custom FontCatalog +
# a hardcoded 4-slot fallback list, the font FILES /usr/share/fonts/{Dotum_nb,Heisei_Kaku_Gothic_nb,
# HeiS_nb,HeiT_nb}.ttf (Korean/Japanese/Simplified-CN/Traditional-CN). Each slot's coverage RANGE is
# derived from that font's own cmap at load, so you extend script coverage simply by swapping a slot
# file - no binary patching. (Verified 2026-07-17.)
#
# We only need to ADD Thai (Cyrillic/Greek/ext-Latin already render via Prelude's WGL set; CJK via the
# stock fonts; astral emoji can't render at all - the JS layer corrupts them to U+FFFD - so the transport
# strips them from names instead). Replacing MORE than one slot is a mistake: the stock CJK fonts also
# supply the virtual-keyboard arrow glyphs, so we keep 3 of 4 stock and repurpose only HeiT (Traditional
# Chinese, least needed) -> Noto Sans Thai.
#
# Usage:  novacom -d <dev> put file:///usr/share/fonts/HeiT_nb.ttf < NotoSansThai-Regular.ttf   (then reboot)
# or run this from the host with novacom on PATH:
set -e
DEV="${1:-topaz-linux}"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "=== backing up stock HeiT_nb.ttf and installing Noto Sans Thai into that fallback slot ==="
novacom -d "$DEV" run file:///bin/sh <<'EOS'
mount -o remount,rw /
[ -f /usr/share/fonts/HeiT_nb.ttf.orig ] || cp /usr/share/fonts/HeiT_nb.ttf /usr/share/fonts/HeiT_nb.ttf.orig
EOS
novacom -d "$DEV" put file:///usr/share/fonts/HeiT_nb.ttf < "$HERE/NotoSansThai-Regular.ttf"
novacom -d "$DEV" run file:///bin/sh <<'EOS'
echo "HeiT_nb.ttf md5: $(md5sum /usr/share/fonts/HeiT_nb.ttf | awk '{print $1}')  (Noto Sans Thai a9c0e86939ccde270fcdca9b7e21759b)"
sync
echo "Reboot for LunaSysMgr to pick it up:  novacom -d <dev> run file:///bin/sh -c '/sbin/tellbootie'"
EOS
echo "Done. Reboot the device; Thai then renders. Keep Dotum/Heisei/HeiS stock (they draw the VKB arrows)."
