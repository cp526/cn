// Sorted list

struct List {
  int value;
  struct List *next;
};

/*@
datatype IntList {
  Nil {},
  Cons { i32 head, IntList tail }
}

function (boolean) validCons(i32 head, IntList tail) {
  match tail {
    Nil {} => { true }
    Cons { head: next, tail: _ } => { head <= next }
  }
}

function [rec] (IntList) insertList(boolean dups, i32 x, IntList xs) {
  match xs {
    Nil {} => { Cons { head: x, tail: Nil {} } }
    Cons { head: head, tail: tail } => {
      if (head < x) {
        Cons { head: head, tail: insertList(dups, x,tail) }
      } else {
        if (!dups && head == x) {
          xs
        } else {
          Cons { head: x, tail: xs }
        }
      }
    }
  }
}

predicate [rec] IntList ListSegmentAux(pointer from, pointer to, i32 prev) {
  if (ptr_eq(from,to)) {
    return Nil {};
  } else {
    take head = Owned<struct List>(from);
    assert(prev <= head.value);
    take tail = ListSegmentAux(head.next, to, head.value);
    return Cons { head: head.value, tail: tail };
  }
}

predicate IntList ListSegment(pointer from, pointer to) {
  take L = ListSegmentAux(from, to, MINi32());
  return L;
}
@*/

void *cn_malloc(unsigned long size);

// void print_list(struct List **xs) {
//   if (xs == 0) {
//     printf("{}\n");
//     return;
//   }

//   struct List *curr = *xs;

//   printf("{");
//   while (curr) {
//     printf("%d, ", curr->value);

//     curr = curr->next;
//   }
//   printf("}\n");
// }

void insert(int x, struct List **xs)
/*@
  requires
    take list_ptr = Owned<struct List*>(xs);
    take list = ListSegment(list_ptr,NULL);
  ensures
    take new_list_ptr = Owned<struct List*>(xs);
    take new_list = ListSegment(new_list_ptr,NULL);
    new_list == insertList(false,x,list);
@*/
{
  struct List *node = (struct List *)cn_malloc(sizeof(struct List));
  node->value = x;

  struct List *prev = 0;
  struct List *cur = *xs;
  while (cur && cur->value < x) {
    prev = cur;
    cur = cur->next;
  }

  if (prev) {
    prev->next = node;
    node->next = cur;
  } else {
    node->next = *xs;
    *xs = node;
  }
}
