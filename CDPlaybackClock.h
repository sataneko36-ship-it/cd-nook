#ifndef CDPlaybackClock_h
#define CDPlaybackClock_h
#include <math.h>
#include <stdbool.h>
typedef struct {
    double value, raw, rawStamp, frameStamp, seekUntil;
    bool valid, running;
} CDPlaybackClock;
static inline double CDClamp(double x, double lo, double hi) { return fmax(lo,fmin(hi,x)); }
static inline void CDClockReset(CDPlaybackClock *c, double value, double now, bool seek) {
    *c = (CDPlaybackClock){ .value=value, .raw=value, .rawStamp=now, .frameStamp=now, .seekUntil=seek?now+.8:0, .valid=true };
}
// VLC 3 publishes coarse time samples. Advance using the monotonic clock;
// correct phase gradually when a new sample arrives instead of repeating it.
static inline double CDClockStep(CDPlaybackClock *c, double raw, double now, bool playing, double rate) {
    if (!c->valid) CDClockReset(c,fmax(0,raw),now,false);
    double dt=CDClamp(now-c->frameStamp,0,.1); c->frameStamp=now;
    if (raw>=0 && now>=c->seekUntil && raw!=c->raw) { c->raw=raw; c->rawStamp=now; }
    if (playing) {
        double age=now-c->rawStamp;
        double target=c->raw+fmin(age,1.5)*1000*rate;
        if (age<1.5 || now<c->seekUntil) {
            double advance=dt*1000*rate;
            double correction=now<c->seekUntil?0:CDClamp((target-c->value)*dt*1.5,-advance*.8,advance*.8);
            c->value+=advance+correction;
        }
    } else if (c->running) {
        c->raw=c->value; c->rawStamp=now;
    }
    if (!c->running && playing) { c->raw=c->value; c->rawStamp=now; }
    c->running=playing;
    return c->value;
}
#endif
