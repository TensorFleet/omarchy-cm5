/* Map the AYN Thor gamepad to a virtual keyboard for tty1 setup (gum).
 * Runs only while /var/lib/omarchy/provisioning/pending exists.
 *
 * A/B/Start = Enter    Select/X = Esc    D-pad/stick = arrows
 * Y = Backspace        L1/R1 = Tab       AYN key = Enter
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define MAX_SRC 16
#define NAME_LEN 256

static int ufd = -1;
static int src_fd[MAX_SRC];
static int nsrc;

static void emit(int type, int code, int val) {
  struct input_event ev;
  memset(&ev, 0, sizeof ev);
  ev.type = type;
  ev.code = code;
  ev.value = val;
  if (write(ufd, &ev, sizeof ev) != sizeof ev)
    perror("uinput write");
}

static void key(int code, int down) {
  if (code <= 0)
    return;
  emit(EV_KEY, code, down ? 1 : 0);
  emit(EV_SYN, SYN_REPORT, 0);
}

static int map_key(int code) {
  switch (code) {
  case BTN_SOUTH:   /* physical south; Thor silkscreen B or A depending on DTB */
  case BTN_EAST:    /* physical east; Thor silkscreen A */
  case BTN_START:
  case KEY_ENTER:
  case KEY_HOME:
  case KEY_F24:     /* gpio AYN key */
    return KEY_ENTER;
  case BTN_SELECT:
  case BTN_WEST:    /* X */
  case KEY_ESC:
  case KEY_BACK:
    return KEY_ESC;
  case BTN_NORTH:   /* Y */
    return KEY_BACKSPACE;
  case BTN_TL:
  case BTN_TR:
    return KEY_TAB;
  case BTN_DPAD_UP:
    return KEY_UP;
  case BTN_DPAD_DOWN:
    return KEY_DOWN;
  case BTN_DPAD_LEFT:
    return KEY_LEFT;
  case BTN_DPAD_RIGHT:
    return KEY_RIGHT;
  default:
    return 0;
  }
}

static int interesting(const char *name, const char *phys) {
  if (name && (strcasestr(name, "gamepad") || strcasestr(name, "rsinput") ||
               strcasestr(name, "gpio-keys-ayn") || strcasestr(name, "ayn")))
    return 1;
  if (phys && (strstr(phys, "rsinput-gamepad") || strstr(phys, "gpio-keys-ayn")))
    return 1;
  return 0;
}

static int open_sources(void) {
  DIR *d = opendir("/dev/input");
  struct dirent *de;
  if (!d)
    return 0;
  while ((de = readdir(d)) && nsrc < MAX_SRC) {
    char path[320], name[NAME_LEN], phys[NAME_LEN];
    int fd;
    if (strncmp(de->d_name, "event", 5) != 0)
      continue;
    snprintf(path, sizeof path, "/dev/input/%s", de->d_name);
    fd = open(path, O_RDONLY | O_NONBLOCK);
    if (fd < 0)
      continue;
    memset(name, 0, sizeof name);
    memset(phys, 0, sizeof phys);
    ioctl(fd, EVIOCGNAME(sizeof name - 1), name);
    ioctl(fd, EVIOCGPHYS(sizeof phys - 1), phys);
    if (!interesting(name, phys)) {
      close(fd);
      continue;
    }
    ioctl(fd, EVIOCGRAB, 1);
    src_fd[nsrc++] = fd;
    fprintf(stderr, "omarchy-thor-kb: grabbed %s (%s)\n", path, name);
  }
  closedir(d);
  return nsrc;
}

static int setup_uinput(void) {
  struct uinput_setup setup;
  int i;
  ufd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
  if (ufd < 0)
    ufd = open("/dev/input/uinput", O_WRONLY | O_NONBLOCK);
  if (ufd < 0)
    return -1;
  ioctl(ufd, UI_SET_EVBIT, EV_KEY);
  ioctl(ufd, UI_SET_EVBIT, EV_SYN);
  ioctl(ufd, UI_SET_EVBIT, EV_REP);
  ioctl(ufd, UI_SET_KEYBIT, KEY_ENTER);
  ioctl(ufd, UI_SET_KEYBIT, KEY_ESC);
  ioctl(ufd, UI_SET_KEYBIT, KEY_UP);
  ioctl(ufd, UI_SET_KEYBIT, KEY_DOWN);
  ioctl(ufd, UI_SET_KEYBIT, KEY_LEFT);
  ioctl(ufd, UI_SET_KEYBIT, KEY_RIGHT);
  ioctl(ufd, UI_SET_KEYBIT, KEY_BACKSPACE);
  ioctl(ufd, UI_SET_KEYBIT, KEY_TAB);
  memset(&setup, 0, sizeof setup);
  snprintf(setup.name, UINPUT_MAX_NAME_SIZE, "Omarchy Thor Keyboard");
  setup.id.bustype = BUS_VIRTUAL;
  setup.id.vendor = 0x1d6b;
  setup.id.product = 0x0200;
  if (ioctl(ufd, UI_DEV_SETUP, &setup) < 0)
    return -1;
  if (ioctl(ufd, UI_DEV_CREATE) < 0)
    return -1;
  /* give udev a moment to create the evdev node before gum starts */
  for (i = 0; i < 10; i++)
    usleep(50000);
  return 0;
}

static void handle_abs(int code, int value, int *held_x, int *held_y) {
  int next = 0;
  if (code == ABS_HAT0X || code == ABS_X || code == ABS_RX) {
    if (value <= -1 && code == ABS_HAT0X)
      next = KEY_LEFT;
    else if (value >= 1 && code == ABS_HAT0X)
      next = KEY_RIGHT;
    else if (code != ABS_HAT0X) {
      if (value < -16000)
        next = KEY_LEFT;
      else if (value > 16000)
        next = KEY_RIGHT;
    }
    if (*held_x && *held_x != next)
      key(*held_x, 0);
    if (next && next != *held_x)
      key(next, 1);
    *held_x = next;
    return;
  }
  if (code == ABS_HAT0Y || code == ABS_Y || code == ABS_RY) {
    if (value <= -1 && code == ABS_HAT0Y)
      next = KEY_UP;
    else if (value >= 1 && code == ABS_HAT0Y)
      next = KEY_DOWN;
    else if (code != ABS_HAT0Y) {
      if (value < -16000)
        next = KEY_UP;
      else if (value > 16000)
        next = KEY_DOWN;
    }
    if (*held_y && *held_y != next)
      key(*held_y, 0);
    if (next && next != *held_y)
      key(next, 1);
    *held_y = next;
  }
}

int main(void) {
  int held_x = 0, held_y = 0;
  int tries;

  if (setup_uinput() < 0) {
    perror("uinput");
    return 1;
  }

  for (tries = 0; nsrc == 0 && tries < 30; tries++) {
    open_sources();
    if (nsrc == 0)
      sleep(1);
  }
  if (nsrc == 0)
    fprintf(stderr, "omarchy-thor-kb: no gamepad yet; waiting\n");

  for (;;) {
    struct pollfd pfd[MAX_SRC];
    int i, n;
    if (nsrc == 0) {
      sleep(1);
      open_sources();
      continue;
    }
    for (i = 0; i < nsrc; i++) {
      pfd[i].fd = src_fd[i];
      pfd[i].events = POLLIN;
    }
    n = poll(pfd, nsrc, 2000);
    if (n <= 0)
      continue;
    for (i = 0; i < nsrc; i++) {
      struct input_event ev;
      if (!(pfd[i].revents & POLLIN))
        continue;
      while (read(src_fd[i], &ev, sizeof ev) == sizeof ev) {
        if (ev.type == EV_KEY) {
          int out = map_key(ev.code);
          if (out && ev.value != 2)
            key(out, ev.value);
        } else if (ev.type == EV_ABS) {
          handle_abs(ev.code, ev.value, &held_x, &held_y);
        }
      }
    }
  }
}
