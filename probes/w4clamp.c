// W4 (docs/wakelock-trace.md §6): clamp the 34s suspend-delay arming.
// When xochitl arms the upkeep timer (CLOCK_BOOTTIME_ALARM, relative,
// exactly 34.000s — the fd39 signature proven by probe W3), replace the
// value with window.conf seconds. Conf is re-read at every arming, so a
// probe run can retune without restarting xochitl; missing/invalid conf
// (or anything >= 34) = untouched stock behavior. Pure libc on purpose —
// inherited by every xochitl child, must load everywhere without effects.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

struct itspec { struct timespec it_interval, it_value; };

#define CONF "/home/root/.pinnedSleepScreen/window.conf"
#define LOGPATH "/tmp/w4clamp.log"
#define LOGCAP (1024 * 1024)
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

static int conf_window(void) {
	char buf[16];
	int fd = open(CONF, O_RDONLY);
	if (fd < 0) return 0;
	int n = (int)read(fd, buf, sizeof buf - 1);
	close(fd);
	if (n <= 0) return 0;
	buf[n] = 0;
	int v = atoi(buf);
	return (v >= 3 && v <= 33) ? v : 0;
}

int timerfd_create(int clockid, int flags) {
	static int (*real)(int, int);
	if (!real) real = dlsym(RTLD_NEXT, "timerfd_create");
	int fd = real ? real(clockid, flags)
	              : (int)syscall(SYS_timerfd_create, clockid, flags);
	if (fd >= 0 && fd < FDMAP) fd_clock[fd] = clockid + 1;
	return fd;
}

int timerfd_settime(int fd, int flags, const struct itspec *nv, struct itspec *ov) {
	static int (*real)(int, int, const struct itspec *, struct itspec *);
	if (!real) real = dlsym(RTLD_NEXT, "timerfd_settime");
	struct itspec mod;
	const struct itspec *use = nv;
	int clockid = (fd >= 0 && fd < FDMAP && fd_clock[fd]) ? fd_clock[fd] - 1 : -1;
	if (nv && clockid == 9 && flags == 0
			&& nv->it_value.tv_sec == 34 && nv->it_value.tv_nsec == 0
			&& nv->it_interval.tv_sec == 0 && nv->it_interval.tv_nsec == 0) {
		int w = conf_window();
		struct timespec now;
		clock_gettime(CLOCK_REALTIME, &now);
		char buf[128];
		int n;
		if (w > 0) {
			mod = *nv;
			mod.it_value.tv_sec = w;
			use = &mod;
			n = snprintf(buf, sizeof buf, "%lld pid=%d fd=%d CLAMP 34s -> %ds\n",
				(long long)now.tv_sec, getpid(), fd, w);
		} else {
			n = snprintf(buf, sizeof buf, "%lld pid=%d fd=%d PASS 34s (conf off)\n",
				(long long)now.tv_sec, getpid(), fd);
		}
		logline(buf, n);
	}
	return real ? real(fd, flags, use, ov)
	            : (int)syscall(SYS_timerfd_settime, fd, flags, use, ov);
}
