#ifndef WHATPORT_CSYSTEM_SHIM_H
#define WHATPORT_CSYSTEM_SHIM_H

#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/sysctl.h>
#include <sys/socket.h>
#include <sys/param.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <signal.h>
#include <pwd.h>
#include <errno.h>
#include <unistd.h>

/// Constants that are defined as arithmetic macros in the SDK and therefore
/// are not importable into Swift directly.
static const int WP_PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN;
static const int WP_MAXPATHLEN = MAXPATHLEN;

#endif
