# imlibpurpleservice (imlibpurpletransport)

**The source no longer lives here.** It was moved out of this monorepo into the standalone shared
repo so it can be shared between checkouts and eventually upstreamed:

    https://github.com/Herrie82/imlibpurpleservice.git   branch: herrie/synergy-revival

That branch is upstream `webOS-ports/imlibpurpleservice` @ `134cf24` plus the 100 commits of
synergy-revival work that used to be vendored under `messaging/imlibpurpleservice/imlibpurpleservice/`
(same content, same commit messages, replayed one-for-one).

## Setup

    git clone https://github.com/Herrie82/imlibpurpleservice.git ~/Documents/GitHub/imlibpurpleservice
    cd ~/Documents/GitHub/imlibpurpleservice && git checkout herrie/synergy-revival

`build.sh`, `packaging/generic/stage.sh` and `messaging/whatsapp/deploy-whatsapp.sh` all resolve the
source through `$IMLIB_REPO`, defaulting to `/home/herrie/Documents/GitHub/imlibpurpleservice`. Set
`IMLIB_REPO=/path/to/checkout` if yours lives elsewhere.

## What still lives here

- `build.sh` — cross-compiles the transport for ARM webOS 3.0.5. The build deps (libpurple staging,
  libtidy, device link stubs, glib staging, db8 headers) stay in this monorepo; only the sources come
  from `$IMLIB_REPO`. Output still lands in `build-arm/` (gitignored) here.
- `neuter-activation-services.sh` — deploy helper, kept for reference. See the warning block in
  `messaging/whatsapp/deploy-whatsapp.sh`: do **not** neuter the activation services; it breaks both
  sends and calls.
