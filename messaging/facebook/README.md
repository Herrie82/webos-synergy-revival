# facebook — Facebook Messenger IM for webOS (TouchPad 3.0.5) via libpurple

Rides the same libpurple 2.14 + ssl-openssl backend as the Teams/Discord/Telegram
ports. The prpl is **dequis/purple-facebook** (`prpl-facebook`), vendored under
`plugin/purple-facebook/`. TLS is delegated to libpurple's SSL plugin, so there is no
extra crypto dependency — the only libs beyond libpurple/glib are **json-glib** (already
on the device for Discord) and **zlib** (in the base system).

## Build the prpl
```bash
cd messaging/facebook
./build-facebook.sh          # -> plugin/purple-facebook/build-arm/libfacebook.stripped.so
```
The script cross-compiles the fixed `FACEBOOKSOURCES` list directly with the ARM
toolchain (replicating purple-facebook's autotools flags) rather than cross-configuring
autotools; `marshal.{c,h}` are generated with the host `glib-genmarshal`. It needs:

- ARM toolchain: `~/x-tools/arm-unknown-linux-gnueabi-gcc125` (+ `~/webos/wpe/env-glibc-gcc125.sh`)
- libpurple 2.14 staging: `messaging/libpurple/` (this repo, gitignored binary)
- glib / json-glib / zlib staging: `~/webos/wpe/staging-glibc-252`

Verify: `readelf -h` → ARM DYN; `nm -D … | grep purple_init_plugin` → 1;
`NEEDED` = libpurple, libjson-glib, libgio/gobject/glib, libz, libc (all on device).

## Install (device connected via novacom)
```bash
BACKEND_PURPLE2=/media/cryptofs/apps/.../backend/lib/purple-2 ./deploy-facebook.sh
```
Then Settings → Accounts → Add account → Facebook (email + password).

## Notes
- Backend (libpurple 2.14 + ssl-openssl TLS 1.3) must already be live from teams-port.
- **Auth**: plain email(or phone/username) + password → stored as the account credential;
  `prpl-facebook` runs the mobile-API login on connect. The generic `type_facebook` →
  `prpl-facebook` mapping in imlibpurpleservice works as-is (no override needed).
- **Reliability**: upstream purple-facebook is lightly maintained and Facebook's mobile
  login endpoint is fragile. Accounts with **two-factor authentication cannot log in**
  (upstream #445), and Facebook security checkpoints/API retirements break login
  periodically. Test against a plain-password account; expect fragility on modern accounts.
