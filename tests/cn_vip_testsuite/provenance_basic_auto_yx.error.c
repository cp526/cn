//CN_VIP #include <stdio.h>
#include <string.h>
#include <inttypes.h>
#include "cn_lemmas.h"
int main() {
  int y=2, x=1;
  int *p = &x + 1;
  int *q = &y;
  //CN_VIP printf("Addresses: p=%p q=%p\n",(void*)p,(void*)q);
  /*CN_VIP*//*@ to_bytes RW<int*>(&p); @*/
  /*CN_VIP*//*@ to_bytes RW<int*>(&q); @*/
  /*CN_VIP*/int result = _memcmp((byte*)&p, (byte*)&q, sizeof(p));
  /*CN_VIP*//*@ from_bytes RW<int*>(&p); @*/
  /*CN_VIP*//*@ from_bytes RW<int*>(&q); @*/
  if (result == 0) {
    *p = 11;  // CN VIP UB
    //CN_VIP printf("x=%d y=%d *p=%d *q=%d\n",x,y,*p,*q);
  }
}
