//CN_VIP #include <stdio.h>
#include <string.h>
#include <stddef.h>
#include <inttypes.h>
#include "cn_lemmas.h"
int main() {
  int y=2, x=1;
  int *p = &x;
  int *q = &y;
  ptrdiff_t offset = q - p; // CN VIP UB
  int *r = p + offset;
  /*CN_VIP*//*@ to_bytes RW<int*>(&r); @*/
  /*CN_VIP*//*@ to_bytes RW<int*>(&q); @*/
  /*CN_VIP*/int result = _memcmp((byte*)&r, (byte*)&q, sizeof(r));
  /*CN_VIP*//*@ from_bytes RW<int*>(&r); @*/
  /*CN_VIP*//*@ from_bytes RW<int*>(&q); @*/
  if (result == 0) {
    *r = 11;
    //CN_VIP printf("y=%d *q=%d *r=%d\n",y,*q,*r);
  }
}
