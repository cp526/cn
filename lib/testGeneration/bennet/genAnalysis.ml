module CF = Cerb_frontend
module BT = BaseTypes
module IT = IndexTerms
module Req = Request
module LC = LogicalConstraints
module Def = Definition
module LAT = LogicalArgumentTypes
module GT = GenTerms
module GD = GenDefinitions.Make (GenTerms)
module GC = GenContext.Make (GenTerms)

let rec is_pure (gt : GT.t) : bool =
  let (GT (gt_, _, _)) = gt in
  match gt_ with
  | Arbitrary | Uniform -> true
  | Pick wgts -> wgts |> List.map snd |> List.for_all is_pure
  | Alloc -> false
  | Call _ -> false (* Could be less conservative... *)
  | Asgn _ -> false
  | Let (_, (_, gt1), gt2) -> is_pure gt1 && is_pure gt2
  | Return _ -> true
  | Assert _ -> false
  | ITE (_, gt_then, gt_else) -> is_pure gt_then && is_pure gt_else
  | Map _ -> false


let get_single_uses ?(pure : bool = false) (gt : GT.t) : Sym.Set.t =
  let union =
    Sym.Map.union (fun _ oa ob ->
      Some
        (let open Option in
         let@ a = oa in
         let@ b = ob in
         return (a + b)))
  in
  let it_value : int option = if pure then Some 1 else None in
  let aux_it (it : IT.t) : int option Sym.Map.t =
    it
    |> IT.free_vars
    |> Sym.Set.to_seq
    |> Seq.map (fun x -> (x, it_value))
    |> Sym.Map.of_seq
  in
  let aux_lc (lc : LC.t) : int option Sym.Map.t =
    lc
    |> LC.free_vars
    |> Sym.Set.to_seq
    |> Seq.map (fun x -> (x, it_value))
    |> Sym.Map.of_seq
  in
  let rec aux (gt : GT.t) : int option Sym.Map.t =
    let (GT (gt_, _, _)) = gt in
    match gt_ with
    | Arbitrary | Uniform | Alloc -> Sym.Map.empty
    | Pick wgts ->
      wgts |> List.map snd |> List.map aux |> List.fold_left union Sym.Map.empty
    | Return it -> aux_it it
    | Call (_, iargs) ->
      iargs |> List.map snd |> List.map aux_it |> List.fold_left union Sym.Map.empty
    | Asgn ((it_addr, _), it_val, gt') ->
      aux gt' :: List.map aux_it [ it_addr; it_val ] |> List.fold_left union Sym.Map.empty
    | Let (_, (x, gt1), gt2) -> Sym.Map.remove x (union (aux gt1) (aux gt2))
    | Assert (lc, gt') -> union (aux gt') (aux_lc lc)
    | ITE (it_if, gt_then, gt_else) ->
      aux_it it_if :: List.map aux [ gt_then; gt_else ]
      |> List.fold_left union Sym.Map.empty
    | Map ((i, _, it_perm), gt') ->
      union
        (aux_it it_perm)
        (gt' |> aux |> Sym.Map.remove i |> Sym.Map.map (Option.map (Int.add 1)))
  in
  aux gt
  |> Sym.Map.filter (fun _ -> Option.equal Int.equal (Some 1))
  |> Sym.Map.bindings
  |> List.map fst
  |> Sym.Set.of_list


let get_recursive_preds (preds : (Sym.t * Def.Predicate.t) list) : Sym.Set.t =
  let get_calls (pred : Def.Predicate.t) : Sym.Set.t =
    pred.clauses
    |> Option.get
    |> List.map (fun (cl : Def.Clause.t) -> cl.packing_ft)
    |> List.map LAT.r_resource_requests
    |> List.flatten
    |> List.map snd
    |> List.map fst
    |> List.map Req.get_name
    |> List.filter_map (fun (n : Req.name) ->
      match n with PName name -> Some name | Owned _ -> None)
    |> Sym.Set.of_list
  in
  let module G = Graph.Persistent.Digraph.Concrete (Sym) in
  let g =
    List.fold_left
      (fun g (fsym, pred) ->
         Sym.Set.fold (fun gsym g' -> G.add_edge g' fsym gsym) (get_calls pred) g)
      G.empty
      preds
  in
  let module Oper = Graph.Oper.P (G) in
  let closure = Oper.transitive_closure g in
  preds
  |> List.map fst
  |> List.filter (fun fsym -> G.mem_edge closure fsym fsym)
  |> Sym.Set.of_list


module SymGraph = Graph.Persistent.Digraph.Concrete (Sym)

open struct
  let get_calls (gd : GD.t) : Sym.Set.t =
    let rec aux (gt : GT.t) : Sym.Set.t =
      let (GT (gt_, _, _)) = gt in
      match gt_ with
      | Arbitrary | Uniform | Alloc | Return _ -> Sym.Set.empty
      | Pick wgts ->
        wgts |> List.map snd |> List.map aux |> List.fold_left Sym.Set.union Sym.Set.empty
      | Call (fsym, _) -> Sym.Set.singleton fsym
      | Asgn (_, _, gt') | Assert (_, gt') | Map (_, gt') -> aux gt'
      | Let (_, (_, gt1), gt2) | ITE (_, gt1, gt2) -> Sym.Set.union (aux gt1) (aux gt2)
    in
    aux gd.body


  module SymGraph = Graph.Persistent.Digraph.Concrete (Sym)
  module Oper = Graph.Oper.P (SymGraph)
end

let get_call_graph (ctx : GC.t) : SymGraph.t =
  ctx
  |> List.map_snd get_calls
  |> List.fold_left
       (fun cg (fsym, calls) ->
          Sym.Set.fold (fun fsym' cg' -> SymGraph.add_edge cg' fsym fsym') calls cg)
       SymGraph.empty
  |> Oper.transitive_closure
