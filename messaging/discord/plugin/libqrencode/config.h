/* Minimal config.h for the in-monorepo libqrencode static build (webOS ARM cross-compile).
 * Upstream generates this via autotools/cmake; we only need the handful of macros the core
 * encoder sources actually reference. Built by build-libqrencode.sh; consumed with -DHAVE_CONFIG_H.
 * (qrenc.c CLI is excluded from the .a, so its extra config knobs are irrelevant.) */
#ifndef QRENCODE_CONFIG_H
#define QRENCODE_CONFIG_H

#define MAJOR_VERSION 4
#define MINOR_VERSION 1
#define MICRO_VERSION 1
#define VERSION "4.1.1"

/* Release builds mark internal helpers static; matches upstream --disable-tests behaviour. */
#define STATIC_IN_RELEASE static

/* WITH_TESTS intentionally left undefined (no in-tree unit-test hooks compiled in). */

#endif /* QRENCODE_CONFIG_H */
