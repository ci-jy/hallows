#include <sys/ioctl.h> // ioctl and constants
#include <sys/ttycom.h>  // ioctl and constants for TIOCPTYGNAME
#include <sys/types.h>
#include <unistd.h> // tcgetpgrp
#include <util.h> // openpty

#ifndef tiocsctty
#define tiocsctty 536900705
#endif

#ifndef tiocswinsz
#define tiocswinsz 2148037735
#endif

#ifndef tiocgwinsz
#define tiocgwinsz 1074295912
#endif
