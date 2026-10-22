/*
 * fake_keyboard.c - hardware-free source keyboard for remap smoke tests.
 *
 * Creates a short-lived uinput keyboard named "fusuma fake source keyboard",
 * prints its event node hint, waits briefly, then emits CAPSLOCK
 * press/release. Use it with a remapper config whose keyboard_name_patterns
 * matches "fusuma fake source keyboard".
 *
 * Requires write access to /dev/uinput.
 */
#include <linux/input.h>
#include <linux/uinput.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

static int ufd = -1;

static void sleep_ms(int ms)
{
    struct timespec ts;
    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    nanosleep(&ts, NULL);
}

static void emit_event(int type, int code, int value)
{
    struct input_event ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = (unsigned short)type;
    ev.code = (unsigned short)code;
    ev.value = value;
    if (write(ufd, &ev, sizeof(ev)) != (ssize_t)sizeof(ev)) {
        perror("write");
    }
}

static void syn(void)
{
    emit_event(EV_SYN, SYN_REPORT, 0);
}

static void create_keyboard(void)
{
    ufd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (ufd < 0) {
        fprintf(stderr, "open /dev/uinput: %s\n", strerror(errno));
        exit(1);
    }

    ioctl(ufd, UI_SET_EVBIT, EV_KEY);
    ioctl(ufd, UI_SET_EVBIT, EV_SYN);
    ioctl(ufd, UI_SET_KEYBIT, KEY_CAPSLOCK);
    ioctl(ufd, UI_SET_KEYBIT, KEY_LEFTCTRL);
    ioctl(ufd, UI_SET_KEYBIT, KEY_A);

    struct uinput_setup setup;
    memset(&setup, 0, sizeof(setup));
    setup.id.bustype = BUS_VIRTUAL;
    setup.id.vendor = 0x0f00;
    setup.id.product = 0x0a11;
    setup.id.version = 1;
    strcpy(setup.name, "fusuma fake source keyboard");

    if (ioctl(ufd, UI_DEV_SETUP, &setup) < 0) {
        perror("UI_DEV_SETUP");
        exit(1);
    }
    if (ioctl(ufd, UI_DEV_CREATE) < 0) {
        perror("UI_DEV_CREATE");
        exit(1);
    }

#ifdef UI_GET_SYSNAME
    char sysname[128];
    memset(sysname, 0, sizeof(sysname));
    if (ioctl(ufd, UI_GET_SYSNAME(sizeof(sysname)), sysname) == 0) {
        fprintf(stderr, "created /dev/input/%s\n", sysname);
    }
#endif
}

static void destroy_keyboard(void)
{
    if (ufd >= 0) {
        ioctl(ufd, UI_DEV_DESTROY);
        close(ufd);
    }
}

int main(void)
{
    create_keyboard();
    sleep_ms(500);

    emit_event(EV_KEY, KEY_CAPSLOCK, 1);
    syn();
    sleep_ms(50);
    emit_event(EV_KEY, KEY_CAPSLOCK, 0);
    syn();

    sleep_ms(500);
    destroy_keyboard();
    return 0;
}
