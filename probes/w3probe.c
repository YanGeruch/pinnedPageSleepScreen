// W3 (docs/wakelock-trace.md §6): log-only LD_PRELOAD interposition of
// timerfd_create/timerfd_settime. Changes nothing; proves where the 34s
// upkeep delay is armed and on which clock class before we clamp it.
// Pure libc on purpose: inherited by every xochitl child (incl. the PDF
// renderer) — must load everywhere without side effects.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

struct itspec { struct timespec it_interval, it_value; };

#define LOGPATH "/tmp/w3probe.log"
#define LOGCAP (4 * 1024 * 1024)
#define FDMAP 1024
static int fd_clock[FDMAP]; /* fd -> clockid + 1 (0 = unknown) */

static void logline(const char *buf, int len) {
	int fd = open(LOGPATH, O_WRONLY | O_CREAT | O_APPEND, 0644);
	if (fd < 0) return;
	struct stat st;
	if (fstat(fd, &st) == 0 && st.st_size < LOGCAP)
		write(fd, buf, len);
	close(fd);
}

int timerfd_create(int clockid, int flags) {
	static int (*real)(int, int);
	if (!real) real = dlsym(RTLD_NEXT, "timerfd_create");
	int fd = real ? real(clockid, flags)
	              : (int)syscall(SYS_timerfd_create, clockid, flags);
	if (fd >= 0 && fd < FDMAP) fd_clock[fd] = clockid + 1;
	struct timespec now;
	clock_gettime(CLOCK_REALTIME, &now);
	char buf[192];
	int n = snprintf(buf, sizeof buf,
		"%lld.%03ld pid=%d create clockid=%d flags=%#x -> fd=%d\n",
		(long long)now.tv_sec, now.tv_nsec / 1000000, getpid(),
		clockid, flags, fd);
	logline(buf, n);
	return fd;
}

int timerfd_settime(int fd, int flags, const struct itspec *nv, struct itspec *ov) {
	static int (*real)(int, int, const struct itspec *, struct itspec *);
	if (!real) real = dlsym(RTLD_NEXT, "timerfd_settime");
	int r = real ? real(fd, flags, nv, ov)
	             : (int)syscall(SYS_timerfd_settime, fd, flags, nv, ov);
	struct timespec now;
	clock_gettime(CLOCK_REALTIME, &now);
	long long vs = nv ? (long long)nv->it_value.tv_sec : -1;
	long vn = nv ? nv->it_value.tv_nsec : 0;
	long long is = nv ? (long long)nv->it_interval.tv_sec : -1;
	int clockid = (fd >= 0 && fd < FDMAP && fd_clock[fd]) ? fd_clock[fd] - 1 : -1;
	/* for TFD_TIMER_ABSTIME armings, also log the delay relative to now */
	char rel[48] = "";
	if (nv && (flags & 1) && clockid >= 0) {
		struct timespec cn;
		if (clock_gettime(clockid, &cn) == 0) {
			long long relms = (vs - cn.tv_sec) * 1000 + (vn - cn.tv_nsec) / 1000000;
			snprintf(rel, sizeof rel, " rel=%lldms", relms);
		}
	}
	char buf[256];
	int n = snprintf(buf, sizeof buf,
		"%lld.%03ld pid=%d settime fd=%d clockid=%d flags=%#x value=%lld.%03lds interval=%llds%s -> %d\n",
		(long long)now.tv_sec, now.tv_nsec / 1000000, getpid(), fd,
		clockid, flags, vs, vn / 1000000, is, rel, r);
	logline(buf, n);
	return r;
}
