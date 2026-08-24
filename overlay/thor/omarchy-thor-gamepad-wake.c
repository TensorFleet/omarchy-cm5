/* Keep Omarchy's idle monitor aware of AYN Thor gamepad button activity.
 *
 * The physical controller is opened non-exclusively, so games still receive
 * every event.  Each button press emits KEY_WAKEUP through a virtual keyboard;
 * if the Omarchy screensaver is currently running, it also emits Escape so
 * the screensaver terminal exits normally.  This never bypasses the lock
 * screen or password authentication.
 */
#define _GNU_SOURCE
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define NAME_LEN 256

static int ufd = -1;

static void emit_event(int type, int code, int value) {
  struct input_event ev;
  memset(&ev, 0, sizeof ev);
  ev.type = type;
  ev.code = code;
  ev.value = value;
  if (write(ufd, &ev, sizeof ev) != (ssize_t)sizeof ev)
    perror("omarchy-thor-gamepad-wake: uinput write");
}

static void tap_key(int code) {
  emit_event(EV_KEY, code, 1);
  emit_event(EV_SYN, SYN_REPORT, 0);
  emit_event(EV_KEY, code, 0);
  emit_event(EV_SYN, SYN_REPORT, 0);
}

static int screensaver_running(void) {
  DIR *proc = opendir("/proc");
  struct dirent *de;
  if (!proc)
    return 0;

  while ((de = readdir(proc))) {
    char path[320], cmdline[4096];
    ssize_t n;
    int fd;
    if (!isdigit((unsigned char)de->d_name[0]))
      continue;
    snprintf(path, sizeof path, "/proc/%s/cmdline", de->d_name);
    fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
      continue;
    n = read(fd, cmdline, sizeof cmdline - 1);
    close(fd);
    if (n <= 0)
      continue;
    cmdline[n] = '\0';
    for (ssize_t i = 0; i < n; i++)
      if (cmdline[i] == '\0')
        cmdline[i] = ' ';
    if (strstr(cmdline, "org.omarchy.screensaver")) {
      closedir(proc);
      return 1;
    }
  }
  closedir(proc);
  return 0;
}

static int is_gamepad(const char *name, const char *phys) {
  if (name && (strcasestr(name, "gamepad") || strcasestr(name, "rsinput")))
    return 1;
  if (phys && strstr(phys, "rsinput-gamepad"))
    return 1;
  return 0;
}

static int open_gamepad(void) {
  DIR *input = opendir("/dev/input");
  struct dirent *de;
  if (!input)
    return -1;

  while ((de = readdir(input))) {
    char path[320], name[NAME_LEN], phys[NAME_LEN];
    int fd;
    if (strncmp(de->d_name, "event", 5) != 0)
      continue;
    snprintf(path, sizeof path, "/dev/input/%s", de->d_name);
    fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0)
      continue;
    memset(name, 0, sizeof name);
    memset(phys, 0, sizeof phys);
    ioctl(fd, EVIOCGNAME(sizeof name - 1), name);
    ioctl(fd, EVIOCGPHYS(sizeof phys - 1), phys);
    if (!is_gamepad(name, phys)) {
      close(fd);
      continue;
    }
    fprintf(stderr, "omarchy-thor-gamepad-wake: watching %s (%s) without grab\n",
            path, name);
    closedir(input);
    return fd;
  }
  closedir(input);
  return -1;
}

static int setup_uinput(void) {
  struct uinput_setup setup;
  ufd = open("/dev/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
  if (ufd < 0)
    ufd = open("/dev/input/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
  if (ufd < 0)
    return -1;
  if (ioctl(ufd, UI_SET_EVBIT, EV_KEY) < 0 ||
      ioctl(ufd, UI_SET_EVBIT, EV_SYN) < 0 ||
      ioctl(ufd, UI_SET_KEYBIT, KEY_WAKEUP) < 0 ||
      ioctl(ufd, UI_SET_KEYBIT, KEY_ESC) < 0)
    return -1;
  memset(&setup, 0, sizeof setup);
  snprintf(setup.name, UINPUT_MAX_NAME_SIZE, "Omarchy Thor Wake Keyboard");
  setup.id.bustype = BUS_VIRTUAL;
  setup.id.vendor = 0x1d6b;
  setup.id.product = 0x0201;
  if (ioctl(ufd, UI_DEV_SETUP, &setup) < 0 || ioctl(ufd, UI_DEV_CREATE) < 0)
    return -1;
  usleep(500000);
  return 0;
}

int main(void) {
  int gamepad = -1;
  if (setup_uinput() < 0) {
    perror("omarchy-thor-gamepad-wake: uinput");
    return 1;
  }

  for (;;) {
    struct pollfd pfd;
    if (gamepad < 0) {
      gamepad = open_gamepad();
      if (gamepad < 0) {
        sleep(1);
        continue;
      }
    }
    pfd.fd = gamepad;
    pfd.events = POLLIN;
    pfd.revents = 0;
    if (poll(&pfd, 1, 2000) < 0) {
      if (errno == EINTR)
        continue;
      perror("omarchy-thor-gamepad-wake: poll");
      close(gamepad);
      gamepad = -1;
      continue;
    }
    if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) {
      close(gamepad);
      gamepad = -1;
      continue;
    }
    if (!(pfd.revents & POLLIN))
      continue;

    for (;;) {
      struct input_event ev;
      ssize_t n = read(gamepad, &ev, sizeof ev);
      if (n == (ssize_t)sizeof ev) {
        if (ev.type == EV_KEY && ev.value == 1) {
          tap_key(KEY_WAKEUP);
          if (screensaver_running())
            tap_key(KEY_ESC);
        }
        continue;
      }
      if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
        break;
      if (n < 0 && errno == EINTR)
        continue;
      close(gamepad);
      gamepad = -1;
      break;
    }
  }
}
