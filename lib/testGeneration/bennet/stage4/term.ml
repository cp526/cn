module CF = Cerb_frontend
module A = CF.AilSyntax
module BT = BaseTypes
module IT = IndexTerms
module LC = LogicalConstraints
module SymGraph = Graph.Persistent.Digraph.Concrete (Sym)
module StringMap = Map.Make (String)
include GenTerms.Make ()

type 'ast annot = (Sym.Set.t * Sym.t, 'ast) GenTerms.annot [@@deriving eq, ord]

type 'recur ast =
  [ `Arbitrary (** Generate arbitrary values *)
  | `PickSizedElab of Sym.t * (Z.t * 'recur annot) list
    (** Pick among a list of options, weighted by the provided [Z.t]s *)
  | `Call of Sym.t * IT.t list
    (** Call a defined generator according to a [Sym.t] with arguments [IT.t list] *)
  | `CallSized of Sym.t * IT.t list * (int * Sym.t)
  | `AsgnElab of ((Sym.t * (Sym.t * BT.t) * IT.t) * Sctypes.t) * IT.t * 'recur annot
    (** Claim ownership and assign a value to a memory location *)
  | `LetStar of (Sym.t * 'recur annot) * 'recur annot (** Backtrack point *)
  | `Return of IT.t (** Monadic return *)
  | `Assert of LC.t * 'recur annot
    (** Assert some [LC.t] are true, backtracking otherwise *)
  | `AssertDomain of Sym.t * BT.t * Abstract.domain * 'recur annot (** Domain assertion *)
  | `ITE of IT.t * 'recur annot * 'recur annot (** If-then-else *)
  | `MapElab of (Sym.t * BT.t * (IT.t * IT.t) * IT.t) * 'recur annot
  | `SplitSizeElab of Sym.t * Sym.Set.t * 'recur annot
  ]
[@@deriving eq, ord]

type t_ = t_ ast [@@deriving eq, ord]

type t = t_ annot [@@deriving eq, ord]

let rec subst_ (su : [ `Term of IT.t | `Rename of Sym.t ] Subst.t) (gt_ : t_) : t_ =
  match gt_ with
  | `Arbitrary -> `Arbitrary
  | `PickSizedElab (pick_var, choices) ->
    `PickSizedElab (pick_var, List.map (fun (w, g) -> (w, subst su g)) choices)
  | `Call (fsym, iargs) -> `Call (fsym, List.map (IT.subst su) iargs)
  | `CallSized (fsym, iargs, sz) -> `CallSized (fsym, List.map (IT.subst su) iargs, sz)
  | `AsgnElab (((backtrack_var, pointer, it_addr), bt), it_val, g') ->
    `AsgnElab
      ( ((backtrack_var, pointer, IT.subst su it_addr), bt),
        IT.subst su it_val,
        subst su g' )
  | `LetStar ((x, gt1), gt2) ->
    let x, gt2 = suitably_alpha_rename_gen su.relevant x gt2 in
    `LetStar ((x, subst su gt1), subst su gt2)
  | `Return it -> `Return (IT.subst su it)
  | `Assert (lc, gt') -> `Assert (LC.subst su lc, subst su gt')
  | `AssertDomain (x, x_bt, domain, gt') -> `AssertDomain (x, x_bt, domain, subst su gt')
  | `ITE (it, gt_then, gt_else) ->
    `ITE (IT.subst su it, subst su gt_then, subst su gt_else)
  | `MapElab ((i, bt, (it_min, it_max), it_perm), gt') ->
    let i', it_min = IT.suitably_alpha_rename su.relevant i it_min in
    let it_max = IT.subst (IT.make_rename ~from:i ~to_:i') it_max in
    let it_perm = IT.subst (IT.make_rename ~from:i ~to_:i') it_perm in
    let gt' = subst (IT.make_rename ~from:i ~to_:i') gt' in
    `MapElab
      ( (i', bt, (IT.subst su it_min, IT.subst su it_max), IT.subst su it_perm),
        subst su gt' )
  | `SplitSizeElab (split_var, syms, gt') -> `SplitSizeElab (split_var, syms, subst su gt')


and subst (su : [ `Term of IT.t | `Rename of Sym.t ] Subst.t) (gt : t) : t =
  let (Annot (gt_, tag, bt, here)) = gt in
  Annot (subst_ su gt_, tag, bt, here)


and alpha_rename_gen x gt =
  let x' = Sym.fresh_same x in
  (x', subst (IT.make_rename ~from:x ~to_:x') gt)


and suitably_alpha_rename_gen syms x gt =
  if Sym.Set.mem x syms then
    alpha_rename_gen x gt
  else
    (x, gt)


let rec map_gen_pre (f : t -> t) (g : t) : t =
  let (Annot (gt_, tag, bt, here)) = f g in
  let gt_ =
    match gt_ with
    | `Arbitrary -> `Arbitrary
    | `PickSizedElab (pick_var, choices) ->
      `PickSizedElab (pick_var, List.map (fun (w, g) -> (w, map_gen_pre f g)) choices)
    | `Call (fsym, its) -> `Call (fsym, its)
    | `CallSized (fsym, its, sz) -> `CallSized (fsym, its, sz)
    | `AsgnElab ((backtrack_info, sct), it_val, gt') ->
      `AsgnElab ((backtrack_info, sct), it_val, map_gen_pre f gt')
    | `LetStar ((x, gt), gt') -> `LetStar ((x, map_gen_pre f gt), map_gen_pre f gt')
    | `Return it -> `Return it
    | `Assert (lcs, gt') -> `Assert (lcs, map_gen_pre f gt')
    | `AssertDomain (x, x_bt, domain, gt') ->
      `AssertDomain (x, x_bt, domain, map_gen_pre f gt')
    | `ITE (it, gt_then, gt_else) ->
      `ITE (it, map_gen_pre f gt_then, map_gen_pre f gt_else)
    | `MapElab ((i, bt, range, it_perm), gt') ->
      `MapElab ((i, bt, range, it_perm), map_gen_pre f gt')
    | `SplitSizeElab (split_var, syms, gt') ->
      `SplitSizeElab (split_var, syms, map_gen_pre f gt')
  in
  Annot (gt_, tag, bt, here)


let rec map_gen_post (f : t -> t) (g : t) : t =
  let (Annot (gt_, tag, bt, here)) = g in
  let gt_ =
    match gt_ with
    | `Arbitrary -> `Arbitrary
    | `PickSizedElab (pick_var, choices) ->
      `PickSizedElab (pick_var, List.map (fun (w, g) -> (w, map_gen_post f g)) choices)
    | `Call (fsym, its) -> `Call (fsym, its)
    | `CallSized (fsym, its, sz) -> `CallSized (fsym, its, sz)
    | `AsgnElab ((backtrack_info, sct), it_val, gt') ->
      `AsgnElab ((backtrack_info, sct), it_val, map_gen_post f gt')
    | `LetStar ((x, gt), gt') -> `LetStar ((x, map_gen_post f gt), map_gen_post f gt')
    | `Return it -> `Return it
    | `Assert (lcs, gt') -> `Assert (lcs, map_gen_post f gt')
    | `AssertDomain (x, x_bt, domain, gt') ->
      `AssertDomain (x, x_bt, domain, map_gen_post f gt')
    | `ITE (it, gt_then, gt_else) ->
      `ITE (it, map_gen_post f gt_then, map_gen_post f gt_else)
    | `MapElab ((i, bt, range, it_perm), gt') ->
      `MapElab ((i, bt, range, it_perm), map_gen_post f gt')
    | `SplitSizeElab (split_var, syms, gt') ->
      `SplitSizeElab (split_var, syms, map_gen_post f gt')
  in
  f (Annot (gt_, tag, bt, here))
