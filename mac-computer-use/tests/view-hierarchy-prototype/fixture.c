#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/proc.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <libproc.h>
#include <limits.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>

/* The marker is created only after this owned fixture has entered the loop. */
__attribute__((used, noinline)) int fixture_spin(void) {
    volatile uint64_t count = 0;
    while (count < 100000) count++;
    const char *path = getenv("MAC_CU_FIXTURE_SPIN_MARKER");
    if (!path) return -1;
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd < 0) return -2;
    ssize_t written = write(fd, "spinning\n", 9);
    close(fd);
    if (written != 9) return -3;
    for (;;) count++;
}

/* This executable is an isolated debugger target and read-only process probe. */
int main(int argc, char **argv) {
    if (argc == 3 && (!strcmp(argv[1], "probe") || !strcmp(argv[1], "inspect"))) {
        char *end = NULL;
        long parsed = strtol(argv[2], &end, 10);
        if (!end || *end || parsed <= 0 || parsed > INT_MAX) return 64;
        int pid = (int)parsed;
        int mib[] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
        struct kinfo_proc info = {0};
        size_t size = sizeof(info);
        if (pid <= 0 || sysctl(mib, 4, &info, &size, NULL, 0) || size != sizeof(info)) return 1;
        char actual[PROC_PIDPATHINFO_MAXSIZE] = {0}, self[PATH_MAX] = {0};
        if (proc_pidpath(pid, actual, sizeof(actual)) <= 0) return 1;
        if (!strcmp(argv[1], "probe") && (!realpath(argv[0], self) || strcmp(actual, self))) return 1;
        printf("%d %lld %d %d %d %d %s\n", info.kp_proc.p_pid,
               (long long)info.kp_proc.p_starttime.tv_sec,
               (int)info.kp_proc.p_starttime.tv_usec, info.kp_proc.p_stat,
               !!(info.kp_proc.p_flag & P_TRACED), info.kp_eproc.e_ppid, actual);
        return 0;
    }
    if (argc != 2 || strcmp(argv[1], "fixture")) return 64;
    setvbuf(stdout, NULL, _IONBF, 0);
    puts("ready");
    for (;;) sleep(1);
}
