#!/bin/sh
# neuter-activation-services.sh  --  DEPRECATED: now RESTORES the services (does NOT neuter).
#
# History / why this reversed: this script used to disable the on-demand LS2/DBus ACTIVATION .service
# files for the transport, to stop a "churn" where a second activated transport collided with the
# upstart-resident one ("Attempted to register for a service name that already exists:
# com.palm.imlibpurple"). That was a MISDIAGNOSIS and neutering broke real features:
#
#   com.palm.imlibpurple.service (MAIN):  the activitymanager fires the outbound "pending
#     messages/commands" watch activities by CALLING palm://com.palm.imlibpurple/sendIM /sendCommand.
#     With the .service gone, ls-hubd rejects that ("Service not listed in service files") so NOTHING
#     sends -- messages + reactions sit folder=outbox status=pending forever (incoming still works,
#     masking it).
#   com.palm.{whatsapp,telegram,signal}.call.service (VoIP):  even though the resident registers
#     com.palm.whatsapp.call IN-PLUGIN (glue/call.c), ls-hubd still needs the .service file to know the
#     name for INBOUND routing -- without it a caller gets "Service does not exist" and CALLS FAIL.
#
# The real cause of the churn was transport CRASHES freeing the bus name (uncaught Util::MojoException
# on an unresolvable prpl). That crash-class is fixed by the createPurpleAccount try/catch (f998f33),
# so with a stable resident these .service files simply route to it -- no activation, no churn.
#
# => Do not neuter anything. This script now just RESTORES any .service left .disabled by the old
#    neuter, so a device that ran the old version is repaired. Reboot afterwards for ls-hubd.
#    NEVER kill -9 the transport (corrupts the PmLog init semaphore) -- SIGTERM / stop imtransport only.

set -e
DBS=/usr/share/dbus-1/system-services
SERVICES="com.palm.imlibpurple.service com.palm.whatsapp.call.service com.palm.telegram.call.service com.palm.signal.call.service"

nr() { printf '%s\n' "$1" | novacom run file://bin/sh; }

nr "mount -o remount,rw / 2>/dev/null || true
for s in $SERVICES; do
  if [ -f $DBS/\$s.disabled ]; then mv $DBS/\$s.disabled $DBS/\$s && echo \"  restored \$s\"; fi
done
mount -o remount,ro / 2>/dev/null || true
echo 'done -- all activation services present; reboot so ls-hubd re-reads its catalog.'"
