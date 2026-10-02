#include "../CDPlaybackClock.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
 CDPlaybackClock c={0}; double last=0,minStep=1e6,maxStep=0;
 for(int f=0;f<600;f++) { double t=f/60.; double raw=floor(t)*1000; double v=CDClockStep(&c,raw,t,true,1);
  if(f>2) { double d=v-last; assert(d>0 && d<35); minStep=fmin(minStep,d);maxStep=fmax(maxStep,d); } last=v;
 }
 double paused=CDClockStep(&c,9000,10,false,1); for(int f=1;f<60;f++) assert(CDClockStep(&c,9000,10+f/60.,false,1)==paused);
 CDClockReset(&c,120000,11,true); assert(CDClockStep(&c,9000,11.1,true,1)>120000);
 CDClockReset(&c,0,12,false); assert(CDClockStep(&c,0,12,true,1)==0);
 printf("coarse 1 Hz source -> 60 Hz continuous: step %.2f..%.2f ms; pause, seek and track reset passed\n",minStep,maxStep);
}
