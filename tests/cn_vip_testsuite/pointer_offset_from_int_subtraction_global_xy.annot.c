#include "refinedc.h"

//CN_VIP #include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <inttypes.h>
#include "cn_lemmas.h"
int x=1, y=2;
int main()
/*CN_VIP*//*@ accesses x; accesses y; requires x == 1i32; @*/
{
  uintptr_t ux = (uintptr_t)&x;
  uintptr_t uy = (uintptr_t)&y;
  uintptr_t offset = uy - ux;
  //CN_VIP printf("Addresses: &x=%"PRIuPTR" &y=%"PRIuPTR\
         " offset=%"PRIuPTR" \n",(unsigned long)ux,(unsigned long)uy,(unsigned long)offset);
#if defined(ANNOT)
  int *p = copy_alloc_id(ux + offset, &y);
#else
  int *p = (int *)(ux + offset);
#endif
  int *q = &y;
  /*CN_VIP*//*@ to_bytes RW<int*>(&p); @*/
  /*CN_VIP*//*@ to_bytes RW<int*>(&q); @*/
  /*CN_VIP*/int result = _memcmp((byte*)&p, (byte*)&q, sizeof(p));
  /*CN_VIP*//*@ from_bytes RW<int*>(&p); @*/
  /*CN_VIP*//*@ from_bytes RW<int*>(&q); @*/
  if (result == 0) {
    *p = 11; // CN VIP UB (no annot)
    //CN_VIP printf("x=%d y=%d *p=%d *q=%d\n",x,y,*p,*q);
    /*CN_VIP*//*@ assert(x == 1i32 && y == 11i32 && *p == 11i32 && *q == 11i32); @*/
  }
}
