#define _GNU_SOURCE

#include <errno.h>
#include <stdint.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#ifndef OCI_FIXTURE_EPOCH
#define OCI_FIXTURE_EPOCH 1789776000
#endif

int clock_gettime(clockid_t clock_id, struct timespec *value) {
  if (clock_id == CLOCK_REALTIME || clock_id == CLOCK_REALTIME_COARSE) {
    value->tv_sec = OCI_FIXTURE_EPOCH;
    value->tv_nsec = 0;
    return 0;
  }
  return (int)syscall(SYS_clock_gettime, clock_id, value);
}

int gettimeofday(struct timeval *value, void *timezone) {
  (void)timezone;
  value->tv_sec = OCI_FIXTURE_EPOCH;
  value->tv_usec = 0;
  return 0;
}

time_t time(time_t *value) {
  const time_t fixed = OCI_FIXTURE_EPOCH;
  if (value != NULL) {
    *value = fixed;
  }
  return fixed;
}
