#include <linux/input.h>
#include <linux/uinput.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <unistd.h>

void shim_setup(void)
{
    prctl(PR_SET_PDEATHSIG, SIGTERM);
}

int shim_open_device(const char *path)
{
    int fd = open(path, O_RDWR);
    return fd < 0 ? -errno : fd;
}

int shim_close(int fd)
{
    return close(fd) == 0 ? 0 : -errno;
}

int shim_grab(int fd)
{
    return ioctl(fd, EVIOCGRAB, 1) == 0 ? 0 : -errno;
}

int shim_ungrab(int fd)
{
    return ioctl(fd, EVIOCGRAB, 0) == 0 ? 0 : -errno;
}

const char *shim_device_name(int fd)
{
    static char name[256];
    name[0] = 0;
    if (ioctl(fd, EVIOCGNAME(sizeof(name) - 1), name) < 0) {
        name[0] = 0;
    }
    return name;
}

int shim_device_id(int fd, void *out)
{
    struct input_id id;
    if (ioctl(fd, EVIOCGID, &id) < 0) return -errno;

    int32_t *o = (int32_t *)out;
    o[0] = id.bustype;
    o[1] = id.vendor;
    o[2] = id.product;
    o[3] = id.version;
    return 0;
}

int shim_all_keys_released(int fd)
{
    unsigned char bits[KEY_MAX / 8 + 1];
    memset(bits, 0, sizeof(bits));
    if (ioctl(fd, EVIOCGKEY(sizeof(bits)), bits) < 0) return -errno;

    for (size_t i = 0; i < sizeof(bits); i++) {
        if (bits[i]) return 0;
    }
    return 1;
}

int shim_absinfo(int fd, int axis, void *out)
{
    struct input_absinfo ai;
    if (ioctl(fd, EVIOCGABS(axis), &ai) < 0) return -errno;

    int32_t *o = (int32_t *)out;
    o[0] = ai.value;
    o[1] = ai.minimum;
    o[2] = ai.maximum;
    o[3] = ai.fuzz;
    o[4] = ai.flat;
    o[5] = ai.resolution;
    return 0;
}

int shim_read_event(int fd, void *out)
{
    struct input_event ev;
    ssize_t n = read(fd, &ev, sizeof(ev));
    if (n != (ssize_t)sizeof(ev)) return n < 0 ? -errno : -1;

    int32_t *o = (int32_t *)out;
    o[0] = ev.type;
    o[1] = ev.code;
    o[2] = ev.value;
    return 0;
}

int shim_open_uinput(void)
{
    int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    return fd < 0 ? -errno : fd;
}

int shim_ui_set_evbit(int fd, int ev)  { return ioctl(fd, UI_SET_EVBIT, ev) == 0 ? 0 : -errno; }
int shim_ui_set_keybit(int fd, int c)  { return ioctl(fd, UI_SET_KEYBIT, c) == 0 ? 0 : -errno; }
int shim_ui_set_relbit(int fd, int c)  { return ioctl(fd, UI_SET_RELBIT, c) == 0 ? 0 : -errno; }
int shim_ui_set_absbit(int fd, int c)  { return ioctl(fd, UI_SET_ABSBIT, c) == 0 ? 0 : -errno; }
int shim_ui_set_mscbit(int fd, int c)  { return ioctl(fd, UI_SET_MSCBIT, c) == 0 ? 0 : -errno; }
int shim_ui_set_propbit(int fd, int c) { return ioctl(fd, UI_SET_PROPBIT, c) == 0 ? 0 : -errno; }

int shim_ui_abs_setup(int fd, int code, int min, int max, int fuzz, int flat, int res)
{
    struct uinput_abs_setup abs;
    memset(&abs, 0, sizeof(abs));
    abs.code = (uint16_t)code;
    abs.absinfo.minimum = min;
    abs.absinfo.maximum = max;
    abs.absinfo.fuzz = fuzz;
    abs.absinfo.flat = flat;
    abs.absinfo.resolution = res;
    return ioctl(fd, UI_ABS_SETUP, &abs) == 0 ? 0 : -errno;
}

int shim_ui_dev_setup(int fd, const char *name, int bustype, int vendor, int product, int version)
{
    struct uinput_setup setup;
    memset(&setup, 0, sizeof(setup));
    strncpy(setup.name, name, UINPUT_MAX_NAME_SIZE - 1);
    setup.id.bustype = (uint16_t)bustype;
    setup.id.vendor = (uint16_t)vendor;
    setup.id.product = (uint16_t)product;
    setup.id.version = (uint16_t)version;
    return ioctl(fd, UI_DEV_SETUP, &setup) == 0 ? 0 : -errno;
}

int shim_ui_dev_create(int fd)
{
    return ioctl(fd, UI_DEV_CREATE, NULL) == 0 ? 0 : -errno;
}

int shim_ui_dev_destroy(int fd)
{
    return ioctl(fd, UI_DEV_DESTROY, NULL) == 0 ? 0 : -errno;
}

int shim_emit(int fd, int type, int code, int value)
{
    struct input_event ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = (uint16_t)type;
    ev.code = (uint16_t)code;
    ev.value = value;

    ssize_t n = write(fd, &ev, sizeof(ev));
    return n == (ssize_t)sizeof(ev) ? 0 : -errno;
}

int shim_wait_any(const int64_t *fds, size_t n, int timeout_ms)
{
    struct pollfd pfd[64];
    if (n > 64) n = 64;

    for (size_t i = 0; i < n; i++) {
        pfd[i].fd = (int)fds[i];
        pfd[i].events = POLLIN;
        pfd[i].revents = 0;
    }

    for (;;) {
        int rc = poll(pfd, (nfds_t)n, timeout_ms);
        if (rc < 0) {
            if (errno == EINTR) continue;
            return -errno;
        }
        if (rc == 0) return -1;

        for (size_t i = 0; i < n; i++) {
            if (pfd[i].revents & (POLLIN | POLLERR | POLLHUP)) return (int)i;
        }
        return -1;
    }
}

static char sin_buf[65536];
static size_t sin_len = 0;
static char sin_line[65536];

int shim_stdin_fill(void)
{
    if (sin_len >= sizeof(sin_buf)) {
        sin_len = 0;
        return -ENOBUFS;
    }

    ssize_t n = read(0, sin_buf + sin_len, sizeof(sin_buf) - sin_len);
    if (n < 0) return -errno;
    sin_len += (size_t)n;
    return (int)n;
}

int shim_stdin_pending(void)
{
    return memchr(sin_buf, '\n', sin_len) != NULL ? 1 : 0;
}

const char *shim_stdin_readline(void)
{
    char *nl = memchr(sin_buf, '\n', sin_len);
    if (!nl) {
        sin_line[0] = 0;
        return sin_line;
    }

    size_t linelen = (size_t)(nl - sin_buf);
    if (linelen >= sizeof(sin_line)) linelen = sizeof(sin_line) - 1;
    memcpy(sin_line, sin_buf, linelen);
    sin_line[linelen] = 0;

    size_t rest = sin_len - (size_t)(nl - sin_buf) - 1;
    memmove(sin_buf, nl + 1, rest);
    sin_len = rest;
    return sin_line;
}

void shim_flush(void)
{
    fflush(NULL);
}
