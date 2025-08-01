module CF = Cerb_frontend
module A = CF.AilSyntax
module BT = BaseTypes
module IT = IndexTerms
module LC = LogicalConstraints
module SymGraph = Graph.Persistent.Digraph.Concrete (Sym)
module StringMap = Map.Make (String)

let bennet = Sym.fresh "bennet"

let transform_gt (gt : Stage3.Term.t) : Term.t =
  let rec aux (vars : Sym.t list) (path_vars : Sym.Set.t) (gt : Stage3.Term.t) : Term.t =
    let last_var = match vars with v :: _ -> v | [] -> bennet in
    let (GenTerms.Annot (gt_, (), bt, loc)) = gt in
    match gt_ with
    | `Arbitrary -> GenTerms.Annot (`Arbitrary, (path_vars, last_var), bt, loc)
    | `PickSized wgts ->
      let choice_var = Sym.fresh_anon () in
      let wgts =
        let wgts =
          let gcd =
            List.fold_left
              (fun x y -> Z.gcd x y)
              (fst (List.hd wgts))
              (List.map fst (List.tl wgts))
          in
          List.map_fst (fun x -> Z.div x gcd) wgts
        in
        let w_sum = List.fold_left Z.add Z.zero (List.map fst wgts) in
        let max_int = Z.of_int Int.max_int in
        let f =
          if Z.leq w_sum max_int then
            fun w -> w
          else
            fun w -> Z.max Z.one (Z.div w (Z.div (Z.add w_sum (Z.pred max_int)) max_int))
        in
        List.map
          (fun (w, gt) ->
             (f w, aux (choice_var :: vars) (Sym.Set.add choice_var path_vars) gt))
          wgts
      in
      GenTerms.Annot (`PickSizedElab (choice_var, wgts), (path_vars, last_var), bt, loc)
    | `Call (fsym, iargs) ->
      GenTerms.Annot (`Call (fsym, iargs), (path_vars, last_var), bt, loc)
    | `CallSized (fsym, iargs, sized) ->
      GenTerms.Annot (`CallSized (fsym, iargs, sized), (path_vars, last_var), bt, loc)
    | `Asgn ((it_addr, sct), it_val, gt_rest) ->
      let rec pointer_of (it : IT.t) : Sym.t * BT.t =
        match it with
        | IT (CopyAllocId { loc = ptr; _ }, _, _)
        | IT (ArrayShift { base = ptr; _ }, _, _)
        | IT (MemberShift (ptr, _, _), _, _) ->
          pointer_of ptr
        | IT (Sym x, bt, _) | IT (Cast (_, IT (Sym x, bt, _)), _, _) -> (x, bt)
        | _ ->
          let pointers =
            it_addr
            |> IT.free_vars_bts
            |> Sym.Map.filter (fun _ bt -> BT.equal bt (BT.Loc ()))
          in
          if not (Sym.Map.cardinal pointers == 1) then
            Cerb_debug.print_debug 2 [] (fun () ->
              Pp.(
                plain
                  (braces
                     (separate_map
                        (comma ^^ space)
                        (fun (x, bt) -> Sym.pp x ^^ colon ^^^ BT.pp bt)
                        (List.of_seq (Sym.Map.to_seq pointers)))
                   ^^^ !^" in "
                   ^^ IT.pp it_addr)));
          if Sym.Map.is_empty pointers then (
            print_endline (Pp.plain (IT.pp it));
            failwith __LOC__);
          Sym.Map.choose pointers
      in
      let backtrack_var = Sym.fresh_anon () in
      let pointer = pointer_of it_addr in
      let gt_rest = aux vars path_vars gt_rest in
      GenTerms.Annot
        ( `AsgnElab (((backtrack_var, pointer, it_addr), sct), it_val, gt_rest),
          (path_vars, last_var),
          bt,
          loc )
    | `LetStar ((x, gt_inner), gt_rest) ->
      let gt_inner = aux vars path_vars gt_inner in
      let gt_rest = aux (x :: vars) path_vars gt_rest in
      GenTerms.Annot (`LetStar ((x, gt_inner), gt_rest), (path_vars, last_var), bt, loc)
    | `Return it -> GenTerms.Annot (`Return it, (path_vars, last_var), bt, loc)
    | `Assert (lc, gt_rest) ->
      let gt_rest = aux vars path_vars gt_rest in
      (match Abstract.abstract_lc vars lc with
       | Some (equiv, (sym, sym_bt), domain) ->
         if equiv then
           GenTerms.Annot
             (`AssertDomain (sym, sym_bt, domain, gt_rest), (path_vars, last_var), bt, loc)
         else
           GenTerms.Annot
             ( `AssertDomain
                 ( sym,
                   sym_bt,
                   domain,
                   GenTerms.Annot (`Assert (lc, gt_rest), (path_vars, last_var), bt, loc)
                 ),
               (path_vars, last_var),
               bt,
               loc )
       | None -> GenTerms.Annot (`Assert (lc, gt_rest), (path_vars, last_var), bt, loc))
    | `ITE (it_if, gt_then, gt_else) ->
      let path_vars = Sym.Set.union path_vars (IT.free_vars it_if) in
      let gt_then = aux vars path_vars gt_then in
      let gt_else = aux vars path_vars gt_else in
      Annot (`ITE (it_if, gt_then, gt_else), (path_vars, last_var), bt, loc)
    | `Map ((i, i_bt, it_perm), gt_inner) ->
      let it_min, it_max = IndexTerms.Bounds.get_bounds (i, i_bt) it_perm in
      let gt_inner = aux (i :: vars) path_vars gt_inner in
      Annot
        ( `MapElab ((i, bt, (it_min, it_max), it_perm), gt_inner),
          (path_vars, last_var),
          bt,
          loc )
    | `SplitSize (syms, gt_rest) ->
      let marker_var = Sym.fresh_anon () in
      let path_vars =
        if TestGenConfig.is_random_size_splits () then
          Sym.Set.add marker_var path_vars
        else
          path_vars
      in
      let gt_rest = aux vars path_vars gt_rest in
      Annot (`SplitSizeElab (marker_var, syms, gt_rest), (path_vars, last_var), bt, loc)
  in
  aux [] Sym.Set.empty gt


let transform_gd ({ filename; recursive; spec; name; iargs; oargs; body } : Stage3.Def.t)
  : Def.t
  =
  { filename; recursive; spec; name; iargs; oargs; body = body |> transform_gt }


let transform (ctx : Stage3.Ctx.t) : Ctx.t = List.map_snd transform_gd ctx
