#include "refinedc.h"

//CN_VIP #include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <inttypes.h>
#include "cn_lemmas.h"
int y=2, x=1;
int main()
/*CN_VIP*//*@ accesses y; accesses x; @*/
{
  int *p = &x+1;
  int *q = &y;
  uintptr_t i = (uintptr_t)p;
  uintptr_t j = (uintptr_t)q;
  /*CN_VIP*//*@ to_bytes RW<int*>(&p); @*/
  /*CN_VIP*//*@ to_bytes RW<int*>(&q); @*/
  /*CN_VIP*/int result = _memcmp((byte*)&p, (byte*)&q, sizeof(p));
  /*CN_VIP*//*@ apply array_bits_eq_8(&p, &q, sizeof<int*>); @*/
  /*CN_VIP*//*@ from_bytes RW<int*>(&p); @*/
  /*CN_VIP*//*@ from_bytes RW<int*>(&q); @*/
  if (result == 0) {
#ifdef ANNOT
    int *r = copy_alloc_id(i, q);
# else
    int *r = (int *)i;
#endif
    *r=11;  // CN VIP UB if ¬ANNOT
    r=r-1;  // CN VIP UB if  ANNOT
    *r=12;
    //CN_VIP printf("x=%d y=%d *q=%d *r=%d\n",x,y,*q,*r);
  }
}

/* NOTE: see tests/pvni_testsuite for why what
   vip_artifact/evaluation_cerberus/results.pdf expects for this test is probably
   wrong. */
