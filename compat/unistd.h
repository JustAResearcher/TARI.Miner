// compat/unistd.h - minimal shim so the reference mean.cu compiles under MSVC.
//
// mean.cu includes <unistd.h> solely for getopt() inside its main(), which the
// Tari driver renames and never calls. This satisfies compilation/linking only.
// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#include <stdio.h>

static char *optarg = 0;
static int   optind = 1, opterr = 1, optopt = 0;

static int getopt(int argc, char *const argv[], const char *optstring) {
    (void)argc; (void)argv; (void)optstring;
    return -1;  // never invoked; the reference main() is dead code here
}
