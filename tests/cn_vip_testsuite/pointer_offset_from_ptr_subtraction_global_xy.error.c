//CN_VIP #include <stdio.h>
#include <string.h>
#include <stddef.h>
#include <inttypes.h>
#include "cn_lemmas.h"
int x=1, y=2;
int main()
/*CN_VIP*//*@ accesses x; accesses y; @*/
{
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
    *r = 11; // is this free of UB?
    //CN_VIP printf("y=%d *q=%d *r=%d\n",y,*q,*r);
  }
}
