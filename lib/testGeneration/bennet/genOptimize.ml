module CF = Cerb_frontend
module BT = BaseTypes
module IT = IndexTerms
module LC = LogicalConstraints
module GT = GenTerms
module GS = GenStatements
module GD = GenDefinitions.Make (GenTerms)
module GC = GenContext.Make (GenTerms)
module GA = GenAnalysis
module Config = TestGenConfig
module StringSet = Set.Make (String)
module StringMap = Map.Make (String)

type opt_pass =
  { name : string;
    transform : GT.t -> GT.t
  }

module FlipIfs = struct
  (* TODO: Improve performance on runway example *)
  let transform (gd : GD.t) : GD.t =
    let iargs = gd.iargs |> List.map fst |> Sym.Set.of_list in
    let rec aux (gt : GT.t) : GT.t =
      let (GT (gt_, _, loc)) = gt in
      match gt_ with
      | Arbitrary | Uniform | Alloc | Call _ | Return _ -> gt
      | Pick wgts -> GT.pick_ (List.map_snd aux wgts) loc
      | ITE (it_if, gt_then, gt_else) ->
        let gt_then, gt_else = (aux gt_then, aux gt_else) in
        if not (Sym.Set.subset (IT.free_vars it_if) iargs) then (
          let wgts1 =
            match gt_then with
            | GT (Pick wgts, _, _) ->
              List.map_snd (fun gt' -> GT.assert_ (T it_if, gt') loc) wgts
            | gt' -> [ (Z.one, GT.assert_ (T it_if, gt') loc) ]
          in
          let wgts2 =
            match gt_else with
            | GT (Pick wgts, _, _) ->
              List.map_snd (fun gt' -> GT.assert_ (T (IT.not_ it_if loc), gt') loc) wgts
            | gt' -> [ (Z.one, GT.assert_ (T (IT.not_ it_if loc), gt') loc) ]
          in
          GT.pick_ (wgts1 @ wgts2) loc)
        else
          GT.ite_ (it_if, gt_then, gt_else) loc
      | Asgn ((it_addr, sct), it_val, gt') ->
        GT.asgn_ ((it_addr, sct), it_val, aux gt') loc
      | Let (backtracks, (x, gt_inner), gt') ->
        GT.let_ (backtracks, (x, aux gt_inner), aux gt') loc
      | Assert (lc, gt') -> GT.assert_ (lc, aux gt') loc
      | Map ((i, i_bt, it_perm), gt_inner) ->
        GT.map_ ((i, i_bt, it_perm), aux gt_inner) loc
    in
    { gd with body = aux gd.body }
end

module Fusion = struct
  module Each = struct
    let check_index_ok (m : Sym.t) (i : Sym.t) (it : IT.t) : bool =
      let rec aux (it : IT.t) : bool =
        let (IT (it_, _bt, _loc)) = it in
        match it_ with
        | MapGet (IT (Sym x, _, _), it_key) when Sym.equal m x ->
          (match IT.is_sym it_key with Some (j, _) -> Sym.equal i j | _ -> false)
        | Const _ | SizeOf _ | OffsetOf _ | Nil _ -> true
        | Sym x -> not (Sym.equal x m)
        | Unop (_, it')
        | EachI ((_, _, _), it')
        | NthTuple (_, it')
        | StructMember (it', _)
        | RecordMember (it', _)
        | Cast (_, it')
        | MemberShift (it', _, _)
        | HasAllocId it'
        | Head it'
        | Tail it'
        | Representable (_, it')
        | Good (_, it')
        | WrapI (_, it')
        | MapConst (_, it')
        | MapDef (_, it') ->
          aux it'
        | Binop (_, it1, it2)
        | StructUpdate ((it1, _), it2)
        | RecordUpdate ((it1, _), it2)
        | ArrayShift { base = it1; ct = _; index = it2 }
        | Cons (it1, it2)
        | CopyAllocId { addr = it1; loc = it2 }
        | Aligned { t = it1; align = it2 }
        | MapGet (it1, it2)
        | Let ((_, it1), it2) ->
          aux it1 && aux it2
        | ITE (it1, it2, it3)
        | NthList (it1, it2, it3)
        | ArrayToList (it1, it2, it3)
        | MapSet (it1, it2, it3) ->
          aux it1 && aux it2 && aux it3
        | Tuple its | Apply (_, its) -> List.for_all aux its
        | Struct (_, xits) | Record xits | Constructor (_, xits) ->
          List.for_all aux (List.map snd xits)
        | Match (it, pits) -> aux it && List.for_all aux (List.map snd pits)
      in
      aux it


    let collect_constraints
          (vars : Sym.Set.t)
          (x : Sym.t)
          ((it_min, it_max) : IT.t * IT.t)
          (gt : GT.t)
      : GT.t * (Sym.t * IT.t) list
      =
      let rec aux (gt : GT.t) : GT.t * (Sym.t * IT.t) list =
        let (GT (gt_, _, loc)) = gt in
        match gt_ with
        | Arbitrary | Uniform | Pick _ | Alloc | Call _ | Return _ | ITE _ | Map _ ->
          (gt, [])
        | Asgn ((it_addr, sct), it_val, gt') ->
          let gt', res = aux gt' in
          (GT.asgn_ ((it_addr, sct), it_val, gt') loc, res)
        | Let (backtracks, (y, gt_inner), gt_rest) ->
          let gt_inner, res = aux gt_inner in
          let gt_rest, res' = aux gt_rest in
          (GT.let_ (backtracks, (y, gt_inner), gt_rest) loc, res @ res')
        | Assert
            ( Forall
                ((i, i_bt), (IT (Binop (Implies, it_perm, it_body), _, loc_implies) as it)),
              gt' )
          when Sym.Set.mem x (IT.free_vars it) && check_index_ok x i it ->
          let it_min', it_max' = IndexTerms.Bounds.get_bounds (i, i_bt) it_perm in
          let gt', res = aux gt' in
          if
            IT.equal it_min it_min'
            && IT.equal it_max it_max'
            && Sym.Set.subset
                 (Sym.Set.remove i (IT.free_vars_list [ it_perm; it_body ]))
                 vars
          then
            (gt', (i, IT.arith_binop Implies (it_perm, it_body) loc_implies) :: res)
          else
            (GT.assert_ (Forall ((i, i_bt), it), gt') loc, res)
        | Assert (lc, gt') ->
          let gt', res = aux gt' in
          (GT.assert_ (lc, gt') loc, res)
      in
      aux gt


    let replace_index (m : Sym.t) ((x, x_bt) : Sym.t * BT.t) (i : Sym.t) (it : IT.t)
      : IT.t
      =
      let aux (it : IT.t) : IT.t =
        let (IT (it_, _bt, loc)) = it in
        match it_ with
        | MapGet (IT (Sym y, _, _), IT (Sym j, _, _)) when Sym.equal m y ->
          if not (Sym.equal i j) then
            failwith (Pp.plain (IT.pp it) ^ " @ " ^ __LOC__);
          IT.sym_ (x, x_bt, loc)
        | _ -> it
      in
      IT.map_term_pre aux it


    let transform (gd : GD.t) : GD.t =
      let rec aux (vars : Sym.Set.t) (gt : GT.t) : GT.t =
        let (GT (gt_, _bt, loc)) = gt in
        match gt_ with
        | Arbitrary | Uniform | Alloc | Call _ | Return _ -> gt
        | Pick wgts -> GT.pick_ (List.map_snd (aux vars) wgts) loc
        | Asgn ((it_addr, sct), it_val, gt') ->
          GT.asgn_ ((it_addr, sct), it_val, aux vars gt') loc
        | Let
            (backtracks, (x, GT (Map ((i, i_bt, it_perm), gt_inner), _, loc_map)), gt_rest)
          ->
          let its_bounds = IndexTerms.Bounds.get_bounds (i, i_bt) it_perm in
          let gt_rest, constraints =
            collect_constraints (Sym.Set.add x vars) x its_bounds gt_rest
          in
          if List.is_empty constraints then
            gt
          else (
            let gt_inner =
              let stmts, gt_last = GS.stmts_of_gt (aux (Sym.Set.add i vars) gt_inner) in
              let sym_bt, stmts', gt_last =
                match gt_last with
                | GT (Return (IT (Sym x, x_bt, _)), _, _) -> ((x, x_bt), [], gt_last)
                | GT (Return it, ret_bt, loc_ret) ->
                  let here = Locations.other __LOC__ in
                  let y = Sym.fresh_anon () in
                  ( (y, ret_bt),
                    [ GS.Let (0, (y, GT.return_ it loc_ret)) ],
                    GT.return_ (IT.sym_ (y, ret_bt, here)) loc_ret )
                | gt' ->
                  let ret_bt = GT.bt gt' in
                  let here = Locations.other __LOC__ in
                  let y = Sym.fresh_anon () in
                  ( (y, ret_bt),
                    [ GS.Let (0, (y, gt')) ],
                    GT.return_ (IT.sym_ (y, ret_bt, here)) (GT.loc gt') )
              in
              let here = Locations.other __LOC__ in
              let stmts'' =
                List.map
                  (fun (j, lc) : GS.t ->
                     Assert
                       (LC.T
                          (replace_index
                             x
                             sym_bt
                             i
                             (IT.subst
                                (IT.make_subst [ (j, IT.sym_ (i, i_bt, here)) ])
                                lc))))
                  constraints
              in
              GS.gt_of_stmts (stmts @ stmts' @ stmts'') gt_last
            in
            GT.let_
              ( backtracks,
                (x, GT.map_ ((i, i_bt, it_perm), gt_inner) loc_map),
                aux (Sym.Set.add x vars) gt_rest )
              loc)
        | Let (backtracks, (x, gt_inner), gt_rest) ->
          GT.let_
            (backtracks, (x, aux vars gt_inner), aux (Sym.Set.add x vars) gt_rest)
            loc
        | Assert (lc, gt') -> GT.assert_ (lc, aux vars gt') loc
        | ITE (it_if, gt_then, gt_else) ->
          GT.ite_ (it_if, aux vars gt_then, aux vars gt_else) loc
        | Map ((i, i_bt, it_perm), gt_inner) ->
          GT.map_ ((i, i_bt, it_perm), aux (Sym.Set.add i vars) gt_inner) loc
      in
      let body = aux (gd.iargs |> List.map fst |> Sym.Set.of_list) gd.body in
      { gd with body }
  end
end

module PartialEvaluation = struct
  type eval_mode =
    | Strict
    | Lazy

  module IndexTerms = struct
    let check_bits_bt (sgn1, sz1) (sgn2, sz2) here : (unit, string) result =
      if not @@ BT.equal_sign sgn1 sgn2 then
        Error ("Mismatched signs at " ^ Locations.simple_location here)
      else if sz1 <> sz2 then
        Error ("Mismatched sizes at " ^ Locations.simple_location here)
      else
        Ok ()


    let eval_num_binop
          (eval : IT.t -> (IT.t, string) result)
          (bt : BT.t)
          (here : Locations.t)
          (f : Z.t -> Z.t -> Z.t)
          (it1 : IT.t)
          (it2 : IT.t)
          (loc : string)
      : (IT.t, string) result
      =
      let ( let@ ) = Result.bind in
      let return = Result.ok in
      let@ it1 = eval it1 in
      let@ it2 = eval it2 in
      match (it1, it2) with
      | IT (Const (Z n1), _, _), IT (Const (Z n2), _, _) ->
        return @@ IT.num_lit_ (f n1 n2) bt here
      | ( IT (Const (Bits ((sgn1, sz1), n1)), _, _),
          IT (Const (Bits ((sgn2, sz2), n2)), _, _) ) ->
        let@ () = check_bits_bt (sgn1, sz1) (sgn2, sz2) here in
        return @@ IT.num_lit_ (BT.normalise_to_range_bt bt (f n1 n2)) bt here
      | _, IT (Const (Z _), _, _) ->
        Error ("Not constant integer `" ^ Pp.plain (IT.pp it1) ^ "` (" ^ loc ^ ")")
      | _, IT (Const (Bits _), _, _) ->
        Error ("Not constant bitvector `" ^ Pp.plain (IT.pp it1) ^ "` (" ^ loc ^ ")")
      | IT (Const (Z _), _, _), _ ->
        Error ("Not constant integer `" ^ Pp.plain (IT.pp it2) ^ "` (" ^ loc ^ ")")
      | IT (Const (Bits _), _, _), _ ->
        Error ("Not constant bitvector `" ^ Pp.plain (IT.pp it2) ^ "` (" ^ loc ^ ")")
      | _, _ ->
        Error
          ("Not constant integer or bitvector `"
           ^ Pp.plain (IT.pp it1)
           ^ "` and `"
           ^ Pp.plain (IT.pp it2)
           ^ "` ("
           ^ loc
           ^ ")")


    let eval_term_generic
          (eval_aux : IT.t -> (IT.t, string) result)
          (prog5 : unit Mucore.file)
          (it : IT.t)
      : (IT.t, string) result
      =
      let ( let@ ) = Result.bind in
      let return = Result.ok in
      let open IT in
      let (IT (t_, bt, here)) = it in
      let eval_num_binop = eval_num_binop eval_aux bt here in
      match t_ with
      | Const _ | Nil _ | MapDef _ -> return it
      | Sym x -> Error (Sym.pp_string x ^ " is free")
      (* Unary ops *)
      | Unop (Not, it') ->
        let@ it' = eval_aux it' in
        (match it' with
         | IT (Const (Bool b), _, _) -> return @@ bool_ (not b) here
         | _ -> Error ("Not constant boolean (" ^ __LOC__ ^ ")"))
      | Unop (Negate, it') ->
        let@ it' = eval_aux it' in
        (match it' with
         | IT (Const (Z n), _, _) -> return @@ num_lit_ (Z.neg n) bt here
         | IT (Const (Bits ((Signed, _), n)), _, _) ->
           return @@ num_lit_ (BT.normalise_to_range_bt bt (Z.neg n)) bt here
         | IT (Const (Bits ((Unsigned, _), _)), _, _) ->
           Error
             ("Can't negate unsigned integer at "
              ^ Locations.simple_location here
              ^ " ("
              ^ __LOC__
              ^ ")")
         | _ -> Error ("Not constant integer or bitvector (" ^ __LOC__ ^ ")"))
      | Unop (BW_CLZ_NoSMT, it') ->
        let@ it' = eval_aux it' in
        (match it' with
         | IT (Const (Bits ((sgn, bits), n)), bt, _) ->
           let open Int64 in
           let reverse_bits (n : Z.t) : Z.t =
             let rec aux (bits : int) (n : int64) (acc : int64) : int64 =
               if bits = 0 then
                 acc
               else (
                 let acc = logor (shift_left acc 1) (logand n (of_int 1)) in
                 aux (bits - 1) (shift_right n 1) acc)
             in
             let to_64, of_64 =
               match sgn with
               | Signed -> (Z.to_int64, Z.of_int64)
               | Unsigned -> (Z.to_int64_unsigned, Z.of_int64_unsigned)
             in
             of_64 (aux bits (to_64 n) (of_int 0))
           in
           let n = BT.normalise_to_range_bt bt (reverse_bits n) in
           eval_aux (arith_unop BW_CTZ_NoSMT (num_lit_ n bt here) here)
         | _ -> Error ("Not constant bitvector (" ^ __LOC__ ^ ")"))
      | Unop (BW_CTZ_NoSMT, it') ->
        let@ it' = eval_aux it' in
        (match it' with
         | IT (Const (Bits ((_, sz), n)), _, _) ->
           let res = Z.trailing_zeros n in
           let res = if res = max_int then sz else res in
           return @@ num_lit_ (Z.of_int res) bt here
         | _ -> Error ("Not constant bitvector (" ^ __LOC__ ^ ")"))
      | Unop (BW_FFS_NoSMT, it') ->
        let@ it' = eval_aux it' in
        (match it' with
         | IT (Const (Bits (_, n)), _, _) ->
           if Z.equal n Z.zero then
             return @@ num_lit_ Z.zero bt here
           else
             let@ it' = return @@ arith_unop BW_CTZ_NoSMT it' here in
             eval_aux (add_ (it', num_lit_ Z.one bt here) here)
         | _ -> Error ("Not constant bitvector (" ^ __LOC__ ^ ")"))
      | Unop (BW_FLS_NoSMT, it') ->
        let@ it' = eval_aux it' in
        (match it' with
         | IT (Const (Bits ((_, sz), n)), bt, _) ->
           if Z.equal n Z.zero then
             return @@ int_lit_ 0 bt here
           else (
             let it' = arith_unop BW_CLZ_NoSMT it' here in
             eval_aux (sub_ (int_lit_ sz bt here, it') here))
         | _ -> Error ("Not constant bitvector (" ^ __LOC__ ^ ")"))
      | Unop (BW_Compl, it') ->
        let@ it' = eval_aux it' in
        (match it' with
         | IT (Const (Bits (_, n)), _, _) ->
           return @@ num_lit_ (BT.normalise_to_range_bt bt (Z.lognot n)) bt here
         | _ -> Error ("Not constant bitvector (" ^ __LOC__ ^ ")"))
      (* Binary ops *)
      | Binop (And, it1, it2) ->
        let@ it1 = eval_aux it1 in
        (match it1 with
         | IT (Const (Bool b1), _, _) -> if b1 then eval_aux it2 else return it1
         | _ -> Error ("Not constant boolean (" ^ __LOC__ ^ ")"))
      | Binop (Or, it1, it2) ->
        let@ it1 = eval_aux it1 in
        (match it1 with
         | IT (Const (Bool b1), _, _) -> if b1 then return it1 else eval_aux it2
         | _ -> Error ("Not constant boolean (" ^ __LOC__ ^ ")"))
      | Binop (Implies, it1, it2) ->
        let@ it1 = eval_aux it1 in
        (match it1 with
         | IT (Const (Bool b1), _, _) ->
           if b1 then eval_aux it2 else return @@ bool_ true here
         | _ -> Error ("Not constant boolean (" ^ __LOC__ ^ ")"))
      | Binop (Add, it1, it2) -> eval_num_binop Z.add it1 it2 __LOC__
      | Binop (Sub, it1, it2) -> eval_num_binop Z.sub it1 it2 __LOC__
      | Binop (Mul, it1, it2) | Binop (MulNoSMT, it1, it2) ->
        eval_num_binop Z.mul it1 it2 __LOC__
      | Binop (Div, it1, it2) | Binop (DivNoSMT, it1, it2) ->
        eval_num_binop Z.div it1 it2 __LOC__
      | Binop (Exp, it1, it2) | Binop (ExpNoSMT, it1, it2) ->
        eval_num_binop (fun n1 n2 -> Z.pow n1 (Z.to_int n2)) it1 it2 __LOC__
      | Binop (Rem, it1, it2) | Binop (RemNoSMT, it1, it2) ->
        eval_num_binop Z.rem it1 it2 __LOC__
      | Binop (Mod, it1, it2) | Binop (ModNoSMT, it1, it2) ->
        eval_num_binop Z.( mod ) it1 it2 __LOC__
      | Binop (BW_Xor, it1, it2) -> eval_num_binop Z.logxor it1 it2 __LOC__
      | Binop (BW_And, it1, it2) -> eval_num_binop Z.logand it1 it2 __LOC__
      | Binop (BW_Or, it1, it2) -> eval_num_binop Z.logor it1 it2 __LOC__
      | Binop (ShiftLeft, _it1, _it2) | Binop (ShiftRight, _it1, _it2) ->
        Error "todo: Bits shifts"
      | Binop (LT, it1, it2) ->
        let@ it1 = eval_aux it1 in
        let@ it2 = eval_aux it2 in
        (match (it1, it2) with
         | IT (Const (Z n1), _, _), IT (Const (Z n2), _, _) ->
           return @@ bool_ (Z.lt n1 n2) here
         | ( IT (Const (Bits ((sgn1, sz1), n1)), _, _),
             IT (Const (Bits ((sgn2, sz2), n2)), _, _) ) ->
           let@ () = check_bits_bt (sgn1, sz1) (sgn2, sz2) here in
           return @@ bool_ (Z.lt n1 n2) here
         | _ -> Error ("Not constant integer or bitvector (" ^ __LOC__ ^ ")"))
      | Binop (LE, it1, it2) ->
        let@ it1 = eval_aux it1 in
        let@ it2 = eval_aux it2 in
        (match (it1, it2) with
         | IT (Const (Z n1), _, _), IT (Const (Z n2), _, _) ->
           return @@ bool_ (Z.leq n1 n2) here
         | ( IT (Const (Bits ((sgn1, sz1), n1)), _, _),
             IT (Const (Bits ((sgn2, sz2), n2)), _, _) ) ->
           let@ () = check_bits_bt (sgn1, sz1) (sgn2, sz2) here in
           return @@ bool_ (Z.leq n1 n2) here
         | _ -> Error ("Not constant integer or bitvector (" ^ __LOC__ ^ ")"))
      | Binop (Min, it1, it2) -> eval_num_binop Z.min it1 it2 __LOC__
      | Binop (Max, it1, it2) -> eval_num_binop Z.max it1 it2 __LOC__
      | Binop (EQ, it1, it2) ->
        let@ it1 = eval_aux it1 in
        let@ it2 = eval_aux it2 in
        (match (it1, it2) with
         | IT (Const c1, _, _), IT (Const c2, _, _) ->
           return @@ bool_ (equal_const c1 c2) here
         | IT (Tuple its1, _, _), IT (Tuple its2, _, _) ->
           eval_aux
             (and_ (List.map (fun its -> eq_ its here) (List.combine its1 its2)) here)
         | IT (Struct (tag1, xits1), _, _), IT (Struct (tag2, xits2), _, _) ->
           if not (Sym.equal tag1 tag2) then
             Error "Ill-typed"
           else (
             let compare (x1, _) (x2, _) = Id.compare x1 x2 in
             let zipped =
               List.combine (List.sort compare xits1) (List.sort compare xits2)
             in
             if List.exists (fun ((x1, _), (x2, _)) -> not (Id.equal x1 x2)) zipped then
               Error "Malformed, different members"
             else
               eval_aux
                 (and_
                    (List.map (fun ((_, it1), (_, it2)) -> eq_ (it1, it2) here) zipped)
                    here))
         | IT (Record xits1, _, _), IT (Record xits2, _, _) ->
           let compare (x1, _) (x2, _) = Id.compare x1 x2 in
           let zipped =
             List.combine (List.sort compare xits1) (List.sort compare xits2)
           in
           if List.exists (fun ((x1, _), (x2, _)) -> not (Id.equal x1 x2)) zipped then
             Error "Malformed, different members"
           else
             eval_aux
               (and_
                  (List.map (fun ((_, it1), (_, it2)) -> eq_ (it1, it2) here) zipped)
                  here)
         | IT (Constructor (constr1, xits1), _, _), IT (Constructor (constr2, xits2), _, _)
           ->
           if not (Sym.equal constr1 constr2) then
             return @@ IT.bool_ false here
           else (
             let compare (x1, _) (x2, _) = Id.compare x1 x2 in
             let zipped =
               List.combine (List.sort compare xits1) (List.sort compare xits2)
             in
             if List.exists (fun ((x1, _), (x2, _)) -> not (Id.equal x1 x2)) zipped then
               Error "Malformed, same constructor, different members"
             else
               eval_aux
                 (and_
                    (List.map (fun ((_, it1), (_, it2)) -> eq_ (it1, it2) here) zipped)
                    here))
         | _ -> Error "Not equal")
      | Binop (LTPointer, _, _) | Binop (LEPointer, _, _) ->
        Error "todo: Pointer inequalities"
      | Binop (SetUnion, _, _)
      | Binop (SetIntersection, _, _)
      | Binop (SetDifference, _, _)
      | Binop (SetMember, _, _)
      | Binop (Subset, _, _) ->
        Error "todo: Sets"
      (* Other ops *)
      | ITE (it_if, it_then, it_else) ->
        let@ it_if = eval_aux it_if in
        (match it_if with
         | IT (Const (Bool b), _, _) -> if b then eval_aux it_then else eval_aux it_else
         | _ -> Error ("Not constant boolean (" ^ __LOC__ ^ ")"))
      | EachI ((i_start, (i_sym, bt'), i_end), it') ->
        let rec loop i =
          if i <= i_end then (
            let su = make_subst [ (i_sym, num_lit_ (Z.of_int i) bt' here) ] in
            let t1 = IT.subst su it' in
            if i = i_end then
              t1
            else
              IT.and2_ (t1, loop (i + 1)) here)
          else
            failwith ("unreachable @ " ^ __LOC__)
        in
        if i_start > i_end then return @@ IT.bool_ true here else eval_aux (loop i_start)
      | NthTuple (i, it') ->
        let@ it' = eval_aux it' in
        (match it' with
         | IT (Tuple its, _, _) -> return @@ List.nth its i
         | _ -> Error ("Not tuple (" ^ __LOC__ ^ ")"))
      | SizeOf ty ->
        return
        @@ IT
             ( Const
                 (Bits
                    ( (Unsigned, Memory.size_of_ctype Sctypes.(Integer Size_t)),
                      Z.of_int (Memory.size_of_ctype ty) )),
               BT.of_sct
                 Memory.is_signed_integer_type
                 Memory.size_of_integer_type
                 Sctypes.(Integer Size_t),
               here )
      | OffsetOf (tag, member) ->
        (match Pmap.find tag prog5.tagDefs with
         | StructDef st ->
           let n = Z.of_int (Option.get (Memory.member_offset st member)) in
           return @@ num_lit_ n bt here
         | _ -> Error "Invalid OffsetOf")
      | MemberShift _ -> Error "todo: MemberShift"
      | ArrayShift _ -> Error "todo: ArrayShift"
      | CopyAllocId _ -> Error "todo: CopyAllocId"
      | HasAllocId _ -> Error "todo: HasAllocId"
      | Head it' ->
        let@ it' = eval_aux it' in
        (match it' with
         | IT (Cons (it_head, _), _, _) -> eval_aux it_head
         | _ -> Error ("Not `Cons` (" ^ __LOC__ ^ ")"))
      | Tail it' ->
        let@ it' = eval_aux it' in
        (match it' with
         | IT (Cons (_, it_tail), _, _) -> eval_aux it_tail
         | _ -> Error ("Not `Cons` (" ^ __LOC__ ^ ")"))
      | NthList _ -> Error "todo: NthList"
      | ArrayToList _ -> Error "todo: ArrayToList"
      | Representable (ty, it') ->
        let struct_decls =
          Pmap.fold
            (fun tag def decls ->
               match def with
               | Mucore.StructDef st -> Sym.Map.add tag st decls
               | _ -> decls)
            prog5.tagDefs
            Sym.Map.empty
        in
        eval_aux (representable struct_decls ty it' here)
      | Good (ty, it') ->
        let struct_decls =
          Pmap.fold
            (fun tag def decls ->
               match def with
               | Mucore.StructDef st -> Sym.Map.add tag st decls
               | _ -> decls)
            prog5.tagDefs
            Sym.Map.empty
        in
        eval_aux (good_value struct_decls ty it' here)
      | Aligned { t; align } ->
        let addr = addr_ t here in
        if not (BT.equal (IT.get_bt addr) (IT.get_bt align)) then
          Error "Mismatched types"
        else
          eval_aux (divisible_ (addr, align) here)
      | Apply (fsym, its) ->
        let@ its =
          List.fold_right
            (fun it acc ->
               let@ acc in
               let@ it = eval_aux it in
               Ok (it :: acc))
            its
            (Ok [])
        in
        (match List.assoc_opt Sym.equal fsym prog5.logical_predicates with
         | Some { args; body = Def it_body; _ } | Some { args; body = Rec_Def it_body; _ }
           ->
           return
           @@ IT.subst (IT.make_subst (List.combine (List.map fst args) its)) it_body
         | Some { body = Uninterp; _ } ->
           Error ("Function " ^ Sym.pp_string fsym ^ " is uninterpreted")
         | None -> Error ("Function " ^ Sym.pp_string fsym ^ " was not found"))
      | Let ((x, it_v), it_rest) ->
        eval_aux (IT.subst (IT.make_subst [ (x, it_v) ]) it_rest)
      | StructMember (it', member) ->
        let@ it' = eval_aux it' in
        (match it' with
         | IT (Struct (_, xits), _, _) -> return @@ List.assoc Id.equal member xits
         | _ -> Error ("Not struct (" ^ __LOC__ ^ ")"))
      | StructUpdate ((it_struct, member), it_value) ->
        let@ it_struct = eval_aux it_struct in
        (match it_struct with
         | IT (Struct (tag, xits), _, _) ->
           let xits =
             List.map
               (fun (x, it) -> (x, if Id.equal x member then it_value else it))
               xits
           in
           return @@ struct_ (tag, xits) here
         | _ -> Error ("Not struct (" ^ __LOC__ ^ ")"))
      | RecordMember (it', member) ->
        let@ it' = eval_aux it' in
        (match it' with
         | IT (Record xits, _, _) -> return @@ List.assoc Id.equal member xits
         | _ -> Error ("Not record (" ^ __LOC__ ^ ")"))
      | RecordUpdate ((it_record, member), it_value) ->
        let@ it_record = eval_aux it_record in
        (match it_record with
         | IT (Record xits, _, _) ->
           let xits =
             List.map
               (fun (x, it) -> (x, if Id.equal x member then it_value else it))
               xits
           in
           return @@ record_ xits here
         | _ -> Error ("Not record (" ^ __LOC__ ^ ")"))
      | Match (it', pits) ->
        let@ it' = eval_aux it' in
        let is_constructor =
          match it' with IT (Constructor _, _, _) -> true | _ -> false
        in
        if not is_constructor then
          return @@ IT (Match (it', pits), bt, here)
        else (
          let rec get_match (it_match : IT.t) (p : BT.t pattern)
            : (Sym.t * IT.t) list option
            =
            let (Pat (p_, _, _)) = p in
            match p_ with
            | PSym x -> Some [ (x, it_match) ]
            | PWild -> Some []
            | PConstructor (constr, xps) ->
              (match it_match with
               | IT (Constructor (constr', xits), _, _) ->
                 if not (Sym.equal constr constr') then
                   None
                 else (
                   let compare (x1, _) (x2, _) = Id.compare x1 x2 in
                   let zipped =
                     List.combine (List.sort compare xits) (List.sort compare xps)
                   in
                   Some
                     (List.flatten
                      @@ List.map
                           (fun ((_, it), (_, p)) ->
                              List.flatten @@ Option.to_list @@ get_match it p)
                           zipped))
               | _ -> None)
          in
          let none = "No pattern matched" in
          Option.to_result
            ~none
            (List.find_map
               (fun (p, it_case) ->
                  let open Option in
                  let@ sub = get_match it' p in
                  Some (IT.subst (IT.make_subst sub) it_case))
               pits))
      | WrapI _ -> Error "todo: WrapI"
      | MapGet (it_m, it_k) ->
        let@ it_m = eval_aux it_m in
        let@ it_k = eval_aux it_k in
        let aux (it_m : IT.t) (it_k : IT.t) : (IT.t, string) result =
          match it_m with
          | IT (MapConst (_, it_body), _, _) -> eval_aux it_body
          | IT (MapSet (it_m', it_k', it_v), _, _) ->
            let@ it_k' = eval_aux it_k' in
            (match (get_num_z it_k, get_num_z it_k') with
             | Some n1, Some n2 when Z.equal n1 n2 -> eval_aux it_v
             | Some _, Some _ -> eval_aux (map_get_ it_m' it_k here)
             | _, _ -> Error "not a valid key")
          | IT (MapDef ((k, _), it_body), _, _) ->
            eval_aux (IT.subst (IT.make_subst [ (k, it_k) ]) it_body)
          | _ -> Error "Attempted MapGet on non-map"
        in
        aux it_m it_k
      | Cast _ -> Error "todo: Cast"
      | Tuple _ | Struct _ | Record _ | Constructor _ | Cons _ | MapConst _ | MapSet _ ->
        failwith "unreachable, specific to evaluation mode"


    let eval_term_strictly (prog5 : unit Mucore.file) (it : IT.t) : (IT.t, string) result =
      let rec eval_aux (it : IT.t) : (IT.t, string) result =
        let ( let@ ) = Result.bind in
        let return = Result.ok in
        let open IT in
        let (IT (t_, bt, here)) = it in
        match t_ with
        (* Shared *)
        | Const _ | Sym _ | Unop _ | Binop _ | ITE _ | EachI _ | NthTuple _
        | StructMember _ | RecordMember _ | MemberShift _ | ArrayShift _ | CopyAllocId _
        | HasAllocId _ | SizeOf _ | OffsetOf _ | Nil _ | Head _ | Tail _ | NthList _
        | ArrayToList _ | Representable _ | Good _ | Aligned _ | MapGet _ | MapDef _
        | Apply _ | Match _ ->
          eval_term_generic eval_aux prog5 it
        (* Strict *)
        | Tuple its ->
          let@ its =
            List.fold_right
              (fun it acc ->
                 let@ acc in
                 let@ it = eval_aux it in
                 Ok (it :: acc))
              its
              (Ok [])
          in
          return @@ tuple_ its here
        | Struct (tag, xits) ->
          let@ xits =
            List.fold_right
              (fun (x, it) acc ->
                 let@ acc in
                 let@ it = eval_aux it in
                 Ok ((x, it) :: acc))
              xits
              (Ok [])
          in
          return @@ struct_ (tag, xits) here
        | StructUpdate ((it_struct, member), it_value) ->
          let@ it_value = eval_aux it_value in
          eval_term_generic
            eval_aux
            prog5
            (IT.IT (StructUpdate ((it_struct, member), it_value), bt, here))
        | Record xits ->
          let@ xits =
            List.fold_right
              (fun (x, it) acc ->
                 let@ acc in
                 let@ it = eval_aux it in
                 Ok ((x, it) :: acc))
              xits
              (Ok [])
          in
          return @@ record_ xits here
        | RecordUpdate ((it_record, member), it_value) ->
          let@ it_value = eval_aux it_value in
          eval_term_generic
            eval_aux
            prog5
            (IT.IT (RecordUpdate ((it_record, member), it_value), bt, here))
        | Constructor (constr, xits) ->
          let@ xits =
            List.fold_right
              (fun (x, it) acc ->
                 let@ acc in
                 let@ it = eval_aux it in
                 Ok ((x, it) :: acc))
              xits
              (Ok [])
          in
          return @@ IT (Constructor (constr, xits), bt, here)
        | Cons (it_head, it_tail) ->
          let@ it_head = eval_aux it_head in
          let@ it_tail = eval_aux it_tail in
          return @@ cons_ (it_head, it_tail) here
        | Let ((x, it_v), it_rest) ->
          let@ it_v = eval_aux it_v in
          eval_term_generic eval_aux prog5 (let_ ((x, it_v), it_rest) here)
        | WrapI _ -> Error "todo: WrapI"
        | MapConst (bt, it') ->
          let@ it' = eval_aux it' in
          return @@ const_map_ bt it' here
        | MapSet (it_m, it_k, it_v) ->
          let@ it_m = eval_aux it_m in
          let@ it_k = eval_aux it_k in
          let@ it_v = eval_aux it_v in
          return @@ map_set_ it_m (it_k, it_v) here
        | Cast _ -> Error "todo: Cast"
      in
      eval_aux it


    let eval_term_lazily (prog5 : unit Mucore.file) (it : IT.t) : (IT.t, string) result =
      let rec eval_aux (it : IT.t) : (IT.t, string) result =
        let open IT in
        let (IT (t_, _, _)) = it in
        match t_ with
        | Const _ | Sym _ | Unop _ | Binop _ | ITE _ | EachI _ | NthTuple _
        | StructMember _ | StructUpdate _ | RecordMember _ | RecordUpdate _ | SizeOf _
        | OffsetOf _ | MemberShift _ | ArrayShift _ | CopyAllocId _ | HasAllocId _ | Nil _
        | Head _ | Tail _ | NthList _ | ArrayToList _ | Representable _ | Good _
        | Aligned _ | MapGet _ | MapDef _ | Apply _ | Let _ | Match _ ->
          eval_term_generic eval_aux prog5 it
        (* Lazy *)
        | Tuple _ | Struct _ | Record _ | Constructor _ | Cons _ | MapConst _ | MapSet _
          ->
          Ok it
        | WrapI _ -> Error "todo: WrapI"
        | Cast _ -> Error "todo: Cast"
      in
      eval_aux it


    let eval ?(mode = Strict) ?(prog5 : unit Mucore.file = Mucore.empty_file) (it : IT.t)
      : (IT.t, string) result
      =
      match mode with
      | Strict -> eval_term_strictly prog5 it
      | Lazy -> eval_term_lazily prog5 it


    let partial_eval
          ?(mode = Strict)
          ?(prog5 : unit Mucore.file = Mucore.empty_file)
          (it : IT.t)
      : IT.t
      =
      let f ?(mode = mode) (it : IT.t) : IT.t =
        match eval ~mode ~prog5 it with Ok it' -> it' | Error _ -> it
      in
      let aux (it : IT.t) : IT.t =
        match it with
        | IT (Apply (fsym, _), _, _) ->
          (* If we lazily evaluate every sub-term, all applications will result in a
           * substitution, diverging. As such, we force strict evaluation of recursive calls
          *)
          (match List.assoc_opt Sym.equal fsym prog5.logical_predicates with
           | Some { body = Def _; _ } -> f it
           | Some { body = Rec_Def _; _ } -> f ~mode:Strict it
           | Some { body = Uninterp; _ } | None -> it)
        | _ -> f it
      in
      IT.map_term_post aux it
  end

  module LogicalConstraints = struct
    let partial_eval
          ?(mode = Strict)
          ?(prog5 : unit Mucore.file = Mucore.empty_file)
          (lc : LC.t)
      : LC.t
      =
      let partial_eval_it = IndexTerms.partial_eval ~mode ~prog5 in
      match lc with
      | T it -> T (partial_eval_it it)
      | Forall ((i, i_bt), IT (Binop (Implies, it_perm, it_body), _, loc_implies)) ->
        LC.Forall
          ( (i, i_bt),
            IT.arith_binop
              Implies
              (partial_eval_it it_perm, partial_eval_it it_body)
              loc_implies )
      | _ -> failwith __LOC__
  end

  module GenTerms = struct
    let partial_eval
          ?(mode = Strict)
          ?(prog5 : unit Mucore.file = Mucore.empty_file)
          (gt : GT.t)
      : GT.t
      =
      let partial_eval_it = IndexTerms.partial_eval ~mode ~prog5 in
      let partial_eval_lc = LogicalConstraints.partial_eval ~mode ~prog5 in
      let rec aux (gt : GT.t) : GT.t =
        let (GT (gt_, bt, loc)) = gt in
        match gt_ with
        | Arbitrary | Uniform | Alloc -> gt
        | Pick wgts -> GT.pick_ (List.map_snd aux wgts) loc
        | Call (fsym, xits) -> GT.call_ (fsym, List.map_snd partial_eval_it xits) bt loc
        | Asgn ((it_addr, sct), it_val, gt') ->
          GT.asgn_ ((partial_eval_it it_addr, sct), partial_eval_it it_val, aux gt') loc
        | Let (backtracks, (x, gt_inner), gt_rest) ->
          GT.let_ (backtracks, (x, aux gt_inner), aux gt_rest) loc
        | Return it -> GT.return_ (partial_eval_it it) loc
        | Assert (lc, gt') -> GT.assert_ (partial_eval_lc lc, aux gt') loc
        | ITE (it_if, gt_then, gt_else) ->
          GT.ite_ (partial_eval_it it_if, aux gt_then, aux gt_else) loc
        | Map ((i, i_bt, it_perm), gt_inner) ->
          GT.map_ ((i, i_bt, partial_eval_it it_perm), aux gt_inner) loc
      in
      aux gt
  end

  let transform (prog5 : unit Mucore.file) = GenTerms.partial_eval ~mode:Lazy ~prog5

  let pass (prog5 : unit Mucore.file) =
    { name = "partial_evaluation"; transform = transform prog5 }
end

module PushPull = struct
  let pull_out_inner_generators (gt : GT.t) : GT.t =
    let aux (gt : GT.t) : GT.t =
      match gt with
      | GT (Let (x_backtracks, (x, gt1), gt2), _, loc_let) ->
        (match gt1 with
         | GT (Asgn ((it_addr, sct), it_val, gt3), _, loc_asgn) ->
           GT.asgn_
             ((it_addr, sct), it_val, GT.let_ (x_backtracks, (x, gt3), gt2) loc_let)
             loc_asgn
         | GT (Let (y_backtracks', (y, gt3), gt4), _, loc_let') ->
           let z = Sym.fresh_anon () in
           let gt4 =
             GT.subst
               (IT.make_subst [ (y, IT.sym_ (z, GT.bt gt3, Locations.other __LOC__)) ])
               gt4
           in
           GT.let_
             (y_backtracks', (z, gt3), GT.let_ (x_backtracks, (x, gt4), gt2) loc_let)
             loc_let'
         | GT (Assert (lc, gt3), _, loc_assert) ->
           GT.assert_ (lc, GT.let_ (x_backtracks, (x, gt3), gt2) loc_let) loc_assert
         | GT (ITE (it_if, gt_then, gt_else), _, loc_ite) ->
           GT.ite_
             ( it_if,
               GT.let_ (x_backtracks, (x, gt_then), gt2) loc_let,
               GT.let_ (x_backtracks, (x, gt_else), gt2) loc_let )
             loc_ite
         | GT (Pick wgts, _, loc_pick) ->
           GT.pick_
             (List.map_snd
                (fun gt' -> GT.let_ (x_backtracks, (x, gt'), gt2) loc_let)
                wgts)
             loc_pick
         | _ -> gt)
      | _ -> gt
    in
    GT.map_gen_post aux gt


  let push_in_outer_generators (gt : GT.t) : GT.t =
    let aux (gt : GT.t) : GT.t =
      match gt with
      | GT (Asgn ((it_addr, sct), it_val, GT (Pick wgts, _, loc_pick)), _, loc_asgn) ->
        GT.pick_
          (List.map_snd (fun gt' -> GT.asgn_ ((it_addr, sct), it_val, gt') loc_asgn) wgts)
          loc_pick
      | GT (Let (x_backtracks, (x, gt_inner), GT (Pick wgts, _, loc_pick)), _, loc_let) ->
        GT.pick_
          (List.map_snd
             (fun gt' -> GT.let_ (x_backtracks, (x, gt_inner), gt') loc_let)
             wgts)
          loc_pick
      | GT (Let (x_backtracks, (x, GT (Pick wgts, _, loc_pick)), gt_rest), _, loc_let) ->
        GT.pick_
          (List.map_snd
             (fun gt' -> GT.let_ (x_backtracks, (x, gt'), gt_rest) loc_let)
             wgts)
          loc_pick
      | GT
          ( Let (x_backtracks, (x, GT (ITE (it_if, gt_then, gt_else), _, loc_ite)), gt2),
            _,
            loc_let ) ->
        GT.ite_
          ( it_if,
            GT.let_ (x_backtracks, (x, gt_then), gt2) loc_let,
            GT.let_ (x_backtracks, (x, gt_else), gt2) loc_let )
          loc_ite
      | GT (Assert (lc, GT (Pick wgts, _, loc_pick)), _, loc_assert) ->
        GT.pick_ (List.map_snd (fun gt' -> GT.assert_ (lc, gt') loc_assert) wgts) loc_pick
      | _ -> gt
    in
    GT.map_gen_pre aux gt


  let transform (gt : GT.t) : GT.t =
    let rec loop (gt : GT.t) : GT.t =
      let old_gt = gt in
      let new_gt = gt |> pull_out_inner_generators |> push_in_outer_generators in
      if GT.equal old_gt new_gt then new_gt else loop new_gt
    in
    loop gt


  let pass = { name = "push_pull"; transform }
end

module BranchPruning = struct
  module Unused = struct
    let transform (gt : GT.t) : GT.t =
      let aux (gt : GT.t) : GT.t =
        match gt with
        | GT (Pick [ (_, gt') ], _, _) -> gt'
        | GT (ITE (it_cond, gt_then, gt_else), _, _) ->
          if IT.is_true it_cond then
            gt_then
          else if IT.is_false it_cond then
            gt_else
          else
            gt
        | _ -> gt
      in
      GT.map_gen_pre aux gt


    let pass = { name = "branch_elimination_unused"; transform }
  end

  module Inconsistent = struct
    let rec contains_false_assertion (gt : GT.t) : bool =
      let (GT (gt_, _, _)) = gt in
      match gt_ with
      | Arbitrary | Uniform | Alloc | Call _ | Return _ -> false
      | Pick wgts ->
        List.is_empty wgts
        || List.for_all (fun (_, gt') -> contains_false_assertion gt') wgts
      | Asgn ((it_addr, _), _, gt') ->
        (match it_addr with
         | IT (Const Null, _, _) -> true
         | _ -> contains_false_assertion gt')
      | Let (_, (_, gt_inner), gt') ->
        contains_false_assertion gt_inner || contains_false_assertion gt'
      | Assert (lc, gt') ->
        (match lc with
         | (T it | Forall (_, it)) when IT.is_false it -> true
         | Forall (_, IT (Binop (Implies, it_perm, it_body), _, _))
           when IT.is_true it_perm && IT.is_false it_body ->
           true
         | _ -> contains_false_assertion gt')
      | ITE (_, gt_then, gt_else) ->
        contains_false_assertion gt_then && contains_false_assertion gt_else
      | Map (_, gt') -> contains_false_assertion gt'


    let transform (gt : GT.t) : GT.t =
      let aux (gt : GT.t) : GT.t =
        match gt with
        | GT (Pick wgts, _, loc_pick) ->
          GT.pick_
            (List.filter (fun (_, gt') -> not (contains_false_assertion gt')) wgts)
            loc_pick
        | GT (ITE (it_if, gt_then, gt_else), _, loc_ite) ->
          if contains_false_assertion gt_else then
            GT.assert_ (T it_if, gt_then) loc_ite
          else if contains_false_assertion gt_then then
            GT.assert_ (T (IT.not_ it_if (IT.get_loc it_if)), gt_else) loc_ite
          else
            gt
        | _ -> gt
      in
      GT.map_gen_post aux gt


    let pass = { name = "branch_elimination_inconsistent"; transform }
  end

  let passes = [ Unused.pass; Inconsistent.pass ]
end

(** This pass performs various inlinings *)
module Inline = struct
  (** This pass inlines generators that just return a constant or symbol *)
  module Returns = struct
    let name = "inline_return"

    let transform (gt : GT.t) : GT.t =
      let aux (gt : GT.t) : GT.t =
        let (GT (gt_, _, _loc)) = gt in
        match gt_ with
        | Let (_, (x, GT (Return it, _, _)), gt') ->
          GT.subst (IT.make_subst [ (x, it) ]) gt'
        | _ -> gt
      in
      GT.map_gen_pre aux gt


    let pass = { name; transform }
  end

  (* This pass inlines terms used a single time *)
  module SingleUse = struct
    module GenTerms = struct
      let name = "inline_single_use_gen"

      let subst (x : Sym.t) (gt_repl : GT.t) (gt : GT.t) : GT.t =
        let aux (gt : GT.t) : GT.t =
          let (GT (gt_, _, _)) = gt in
          match gt_ with
          | Return (IT (Sym y, _, _)) when Sym.equal x y -> gt_repl
          | _ -> gt
        in
        GT.map_gen_post aux gt


      let of_symset (s : Sym.Set.t) : bool Sym.Map.t =
        s |> Sym.Set.to_seq |> Seq.map (fun x -> (x, false)) |> Sym.Map.of_seq


      let union = Sym.Map.union (fun _ a b -> Some (not (a || b)))

      let rec transform_aux (gt : GT.t) : GT.t * bool Sym.Map.t =
        let (GT (gt_, _, loc)) = gt in
        match gt_ with
        | Arbitrary | Uniform | Alloc -> (gt, Sym.Map.empty)
        | Pick wgts ->
          let wgts, only_ret =
            wgts
            |> List.map_snd transform_aux
            |> List.map (fun (a, (b, c)) -> ((a, b), c))
            |> List.split
          in
          (GT.pick_ wgts loc, List.fold_left union Sym.Map.empty only_ret)
        | Call (_fsym, xits) ->
          ( gt,
            xits
            |> List.map snd
            |> List.map IT.free_vars
            |> List.map of_symset
            |> List.fold_left union Sym.Map.empty )
        | Asgn ((it_addr, sct), it_val, gt') ->
          let only_ret =
            [ it_addr; it_val ]
            |> List.map IT.free_vars
            |> List.map of_symset
            |> List.fold_left union Sym.Map.empty
          in
          let gt', only_ret' = transform_aux gt' in
          (GT.asgn_ ((it_addr, sct), it_val, gt') loc, union only_ret only_ret')
        | Let (backtracks, (x, gt_inner), gt') ->
          let gt', only_ret = transform_aux gt' in
          let only_ret = Sym.Map.remove x only_ret in
          if Option.equal Bool.equal (Sym.Map.find_opt x only_ret) (Some true) then
            (subst x gt_inner gt', only_ret)
          else (
            let gt_inner, only_ret' = transform_aux gt_inner in
            (GT.let_ (backtracks, (x, gt_inner), gt') loc, union only_ret only_ret'))
        | Return it ->
          ( gt,
            (match IT.is_sym it with
             | Some (x, _bt) -> Sym.Map.singleton x true
             | None -> it |> IT.free_vars |> of_symset) )
        | Assert (lc, gt') ->
          let only_ret = lc |> LC.free_vars |> of_symset in
          let gt', only_ret' = transform_aux gt' in
          (GT.assert_ (lc, gt') loc, union only_ret only_ret')
        | ITE (it_if, gt_then, gt_else) ->
          let only_ret = it_if |> IT.free_vars |> of_symset in
          let gt_then, only_ret' = transform_aux gt_then in
          let gt_else, only_ret'' = transform_aux gt_else in
          ( GT.ite_ (it_if, gt_then, gt_else) loc,
            [ only_ret; only_ret'; only_ret'' ] |> List.fold_left union Sym.Map.empty )
        | Map ((i, i_bt, it_perm), gt_inner) ->
          let only_ret = it_perm |> IT.free_vars |> Sym.Set.remove i |> of_symset in
          let gt_inner, only_ret' = transform_aux gt_inner in
          let only_ret' = only_ret' |> Sym.Map.remove i |> Sym.Map.map (fun _ -> false) in
          (GT.map_ ((i, i_bt, it_perm), gt_inner) loc, union only_ret only_ret')


      let transform (gt : GT.t) : GT.t = fst (transform_aux gt)

      let pass = { name; transform }
    end

    let passes = [ GenTerms.pass ]
  end

  let passes = Returns.pass :: SingleUse.passes
end

(** This pass breaks down constraints, so that
    other passes can optimize more *)
module SplitConstraints = struct
  module Conjunction = struct
    let name = "split_conjunction"

    let rec cnf_ (e : BT.t IT.term) : BT.t IT.term =
      match e with
      | Unop (Not, e') ->
        (match cnf e' with
         (* Double negation elimination *)
         | IT (Unop (Not, IT (e, _, _)), _, _) -> e
         (* Flip inequalities *)
         | IT (Binop (LT, e1, e2), _, _) -> Binop (LE, e2, e1)
         | IT (Binop (LE, e1, e2), _, _) -> Binop (LT, e2, e1)
         (* De Morgan's Law *)
         | IT (Binop (And, e1, e2), info, loc) ->
           Binop
             ( Or,
               cnf (IT.IT (Unop (Not, e1), info, loc)),
               cnf (IT (Unop (Not, e2), info, loc)) )
         | IT (Binop (Or, e1, e2), info, loc) ->
           Binop
             ( And,
               cnf (IT (Unop (Not, e1), info, loc)),
               cnf (IT (Unop (Not, e2), info, loc)) )
         (* Otherwise *)
         | e'' -> Unop (Not, e''))
      | Binop (Or, e1, e2) ->
        (match (cnf e1, cnf e2) with
         (* Distribute disjunction *)
         | e', IT (Binop (And, e_x, e_y), info, loc)
         | IT (Binop (And, e_x, e_y), info, loc), e' ->
           Binop
             ( And,
               cnf (IT (Binop (Or, e', e_x), info, loc)),
               cnf (IT (Binop (Or, e', e_y), info, loc)) )
         | e1, e2 -> Binop (Or, e1, e2))
      | _ -> e


    and cnf (e : IT.t) : IT.t =
      let (IT (e, info, loc)) = e in
      IT (cnf_ e, info, loc)


    let listify_constraints (it : IT.t) : IT.t list =
      let rec loop (c : IT.t) : IT.t list =
        match c with IT (Binop (And, e1, e2), _, _) -> loop e1 @ loop e2 | _ -> [ c ]
      in
      loop it


    let transform (gt : GT.t) : GT.t =
      let aux (gt : GT.t) : GT.t =
        let (GT (gt_, _bt, loc)) = gt in
        match gt_ with
        | Assert (T it, gt') ->
          it
          |> cnf
          |> listify_constraints
          |> List.fold_left (fun gt_rest it' -> GT.assert_ (LC.T it', gt_rest) loc) gt'
        | Assert (Forall ((i_sym, i_bt), it), gt') ->
          let its_in, its_out =
            it
            |> cnf
            |> listify_constraints
            |> List.partition (fun it' -> Sym.Set.mem i_sym (IT.free_vars it'))
          in
          let gt_forall =
            GT.assert_ (LC.Forall ((i_sym, i_bt), IT.and_ its_in loc), gt') loc
          in
          List.fold_left
            (fun gt_rest it' -> GT.assert_ (LC.T it', gt_rest) loc)
            gt_forall
            its_out
        | _ -> gt
      in
      GT.map_gen_pre aux gt


    let pass = { name; transform }
  end

  module Let = struct
    let name = "split_let"

    let transform (gt : GT.t) : GT.t =
      let aux (gt : GT.t) : GT.t =
        let (GT (gt_, _bt, loc)) = gt in
        match gt_ with
        | Assert (T (IT (Let ((x, it_inner), it_rest), _, loc_let)), gt') ->
          GT.let_
            ( 0,
              (x, GT.return_ it_inner (IT.get_loc it_inner)),
              GT.assert_ (LC.T it_rest, gt') loc )
            loc_let
        | Assert (Forall ((_i_sym, _i_bt), IT (Let _, _, _)), _) ->
          (* TODO: Pull out lets that don't refer to `i_sym` *)
          gt
        | _ -> gt
      in
      GT.map_gen_pre aux gt


    let pass = { name; transform }
  end

  module ITE = struct
    let name = "split_ite"

    let transform (gt : GT.t) : GT.t =
      let aux (gt : GT.t) : GT.t =
        let (GT (gt_, _bt, loc)) = gt in
        match gt_ with
        | Assert (T (IT (ITE (it_if, it_then, it_else), _, loc_ite)), gt') ->
          GT.ite_
            (it_if, GT.assert_ (T it_then, gt') loc, GT.assert_ (T it_else, gt') loc)
            loc_ite
        | _ -> gt
      in
      GT.map_gen_pre aux gt


    let pass = { name; transform }
  end

  let rec is_external (gt : GT.t) : bool =
    let (GT (gt_, _, _)) = gt in
    match gt_ with
    | Arbitrary | Uniform | Alloc | Return _ -> false
    | Call _ -> true
    | Pick wgts -> wgts |> List.map snd |> List.exists is_external
    | Asgn (_, _, gt_rest) -> is_external gt_rest
    | Let (_, (_, gt_inner), gt_rest) -> is_external gt_inner || is_external gt_rest
    | Assert (_, gt_rest) -> is_external gt_rest
    | ITE (_, gt_then, gt_else) -> is_external gt_then || is_external gt_else
    | Map (_, gt_inner) -> is_external gt_inner


  module Disjunction = struct
    let name = "split_disjunction"

    let rec dnf_ (e : BT.t IT.term) : BT.t IT.term =
      match e with
      | Unop (Not, e') ->
        (match dnf e' with
         (* Double negation elimination *)
         | IT (Unop (Not, IT (e, _, _)), _, _) -> e
         (* Flip inequalities *)
         | IT (Binop (LT, e1, e2), _, _) -> Binop (LE, e2, e1)
         | IT (Binop (LE, e1, e2), _, _) -> Binop (LT, e2, e1)
         (* De Morgan's Law *)
         | IT (Binop (And, e1, e2), info, loc) ->
           Binop
             ( Or,
               dnf (IT.IT (Unop (Not, e1), info, loc)),
               dnf (IT (Unop (Not, e2), info, loc)) )
         | IT (Binop (Or, e1, e2), info, loc) ->
           Binop
             ( And,
               dnf (IT (Unop (Not, e1), info, loc)),
               dnf (IT (Unop (Not, e2), info, loc)) )
         (* Otherwise *)
         | e'' -> Unop (Not, e''))
      | Binop (And, e1, e2) ->
        (match (dnf e1, dnf e2) with
         (* Distribute conjunctions *)
         | e', IT (Binop (Or, e_x, e_y), info, loc)
         | IT (Binop (Or, e_x, e_y), info, loc), e' ->
           Binop
             ( Or,
               dnf (IT (Binop (And, e', e_x), info, loc)),
               dnf (IT (Binop (And, e', e_y), info, loc)) )
         | e1, e2 -> Binop (And, e1, e2))
      | _ -> e


    and dnf (e : IT.t) : IT.t =
      let (IT (e, info, loc)) = e in
      IT (dnf_ e, info, loc)


    let listify_constraints (it : IT.t) : IT.t list =
      let rec loop (c : IT.t) : IT.t list =
        match c with IT (Binop (Or, e1, e2), _, _) -> loop e1 @ loop e2 | _ -> [ c ]
      in
      loop it


    let transform (gt : GT.t) : GT.t =
      let rec aux (ext : Sym.Set.t) (gt : GT.t) : GT.t =
        let (GT (gt_, _bt, loc)) = gt in
        match gt_ with
        | Arbitrary | Uniform | Alloc | Call _ | Return _ -> gt
        | Pick wgts -> GT.pick_ (List.map_snd (aux ext) wgts) loc
        | Asgn ((it_addr, sct), it_val, gt_rest) ->
          GT.asgn_ ((it_addr, sct), it_val, aux ext gt_rest) loc
        | Let (backtracks, (x, gt_inner), gt_rest) ->
          let gt_inner = aux ext gt_inner in
          let ext = if is_external gt_inner then Sym.Set.add x ext else ext in
          GT.let_ (backtracks, (x, gt_inner), aux ext gt_rest) loc
        | Assert (T it, gt') ->
          let it = dnf it in
          let gt' = aux ext gt' in
          (match it with
           | IT (Binop (Or, _, _), _, _) ->
             let its_split, its_left =
               it
               |> listify_constraints
               |> List.partition (fun it' ->
                 match it with
                 | IT (Binop (EQ, IT (Sym x, _, _), _), _, _) when not (Sym.Set.mem x ext)
                   ->
                   true
                 | IT (Binop (EQ, _, IT (Sym x, _, _)), _, _) when not (Sym.Set.mem x ext)
                   ->
                   true
                 | _ -> Sym.Set.disjoint ext (IT.free_vars it'))
             in
             let gt' =
               if List.is_empty its_left then
                 gt'
               else (
                 let it' =
                   List.fold_left
                     (fun it1 it2 -> IT.or2_ (it1, it2) loc)
                     (List.hd its_left)
                     (List.tl its_left)
                 in
                 GT.assert_ (T it', gt') loc)
             in
             let cases =
               its_split |> List.map (fun it' -> (Z.one, GT.assert_ (T it', gt') loc))
             in
             GT.pick_ cases loc
           | _ -> GT.assert_ (T it, gt') loc)
        | Assert ((Forall _ as lc), gt_rest) -> GT.assert_ (lc, aux ext gt_rest) loc
        | ITE (it_if, gt_then, gt_else) ->
          GT.ite_ (it_if, aux ext gt_then, aux ext gt_else) loc
        | Map ((i, i_bt, it_perm), gt_inner) ->
          GT.map_ ((i, i_bt, it_perm), aux ext gt_inner) loc
      in
      aux Sym.Set.empty gt


    let pass = { name; transform }
  end

  module Implication = struct
    let name = "split_implication"

    let transform (gt : GT.t) : GT.t =
      let aux (gt : GT.t) : GT.t =
        let (GT (gt_, _bt, loc)) = gt in
        match gt_ with
        | Assert (T (IT (Binop (Implies, it_if, it_then), _, loc_implies)), gt') ->
          GT.ite_ (it_if, GT.assert_ (T it_then, gt') loc, gt') loc_implies
        | _ -> gt
      in
      GT.map_gen_pre aux gt


    let pass = { name; transform }
  end

  let passes =
    [ Conjunction.pass; Let.pass; ITE.pass; Disjunction.pass; Implication.pass ]
end

(** This pass uses [Simplify] to rewrite [IndexTerms.t] *)
module TermSimplification = struct
  let name = "simplify_term"

  let transform (prog5 : unit Mucore.file) (gt : GT.t) : GT.t =
    let globals =
      { Global.empty with
        logical_functions = Sym.Map.of_seq (List.to_seq prog5.logical_predicates)
      }
    in
    let simp_it (it : IT.t) : IT.t =
      Simplify.IndexTerms.simp ~inline_functions:true (Simplify.default globals) it
    in
    let simp_lc (lc : LC.t) : LC.t =
      Simplify.LogicalConstraints.simp
        ~inline_functions:true
        (Simplify.default globals)
        lc
    in
    let aux (gt : GT.t) : GT.t =
      let (GT (gt_, bt, loc)) = gt in
      match gt_ with
      | Call (fsym, iargs) -> GT.call_ (fsym, List.map_snd simp_it iargs) bt loc
      | Asgn ((it_addr, sct), it_val, gt') ->
        GT.asgn_ ((simp_it it_addr, sct), simp_it it_val, gt') loc
      | Return it -> GT.return_ (simp_it it) loc
      | Assert (lc, gt') -> GT.assert_ (simp_lc lc, gt') loc
      | ITE (it_if, gt_then, gt_else) -> GT.ite_ (simp_it it_if, gt_then, gt_else) loc
      | Map ((i, i_bt, it_perm), gt') -> GT.map_ ((i, i_bt, simp_it it_perm), gt') loc
      | _ -> gt
    in
    GT.map_gen_pre aux gt


  let pass (prog5 : unit Mucore.file) = { name; transform = transform prog5 }
end

(** This pass performs rewrites [Simplify] would ideally do *)
module TermSimplification' = struct
  let name = "simplify_term"

  let simplify_it (it : IT.t) : IT.t =
    let aux (it : IT.t) : IT.t =
      let (IT.IT (it_, bt, loc)) = it in
      match it_ with
      | Binop
          ( Add,
            IT (Binop (Add, it1, IT (Const (Bits (_, n1)), _, _)), _, _),
            IT (Const (Bits ((sgn, sz), n2)), _, _) )
      | Binop
          ( Add,
            IT (Const (Bits ((sgn, sz), n2)), _, _),
            IT (Binop (Add, it1, IT (Const (Bits (_, n1)), _, _)), _, _) )
        when BT.fits_range (sgn, sz) (Z.add n1 n2) ->
        IT.add_ (it1, IT.num_lit_ (Z.add n1 n2) (Bits (sgn, sz)) loc) loc
      | Binop
          ( Add,
            IT (Binop (Add, IT (Const (Bits (_, n1)), _, _), it1), _, _),
            IT (Const (Bits ((sgn, sz), n2)), _, _) )
      | Binop
          ( Add,
            IT (Const (Bits ((sgn, sz), n2)), _, _),
            IT (Binop (Add, IT (Const (Bits (_, n1)), _, _), it1), _, _) )
        when BT.fits_range (sgn, sz) (Z.add n1 n2) ->
        IT.add_ (it1, IT.num_lit_ (Z.add n1 n2) (Bits (sgn, sz)) loc) loc
      | Binop
          ( Add,
            IT (Binop (Sub, it1, IT (Const (Bits (_, n1)), _, _)), _, _),
            IT (Const (Bits ((sgn, sz), n2)), _, _) )
      | Binop
          ( Add,
            IT (Const (Bits ((sgn, sz), n2)), _, _),
            IT (Binop (Sub, it1, IT (Const (Bits (_, n1)), _, _)), _, _) )
        when BT.fits_range (sgn, sz) (Z.sub n1 n2) ->
        IT.add_ (it1, IT.num_lit_ (Z.sub n1 n2) (Bits (sgn, sz)) loc) loc
      | Binop
          ( EQ,
            IT
              ( Binop (Mul, IT (Binop (Div, IT (Sym x, x_bt, x_loc), it1), _, _), it2),
                _,
                _ ),
            IT (Sym x', _, _) )
      | Binop
          ( EQ,
            IT
              ( Binop (MulNoSMT, IT (Binop (Div, IT (Sym x, x_bt, x_loc), it1), _, _), it2),
                _,
                _ ),
            IT (Sym x', _, _) )
      | Binop
          ( EQ,
            IT
              ( Binop (Mul, IT (Binop (DivNoSMT, IT (Sym x, x_bt, x_loc), it1), _, _), it2),
                _,
                _ ),
            IT (Sym x', _, _) )
      | Binop
          ( EQ,
            IT
              ( Binop
                  ( MulNoSMT,
                    IT (Binop (DivNoSMT, IT (Sym x, x_bt, x_loc), it1), _, _),
                    it2 ),
                _,
                _ ),
            IT (Sym x', _, _) )
        when Sym.equal x x' && IT.equal it1 it2 ->
        IT.eq_
          (IT.mod_ (IT.sym_ (x, x_bt, x_loc), it1) loc, IT.num_lit_ Z.zero x_bt loc)
          loc
      | Binop
          ( EQ,
            IT (Sym x, x_bt, x_loc),
            IT (Binop (Mul, IT (Binop (Div, IT (Sym x', _, _), it1), _, _), it2), _, _) )
      | Binop
          ( EQ,
            IT (Sym x, x_bt, x_loc),
            IT
              (Binop (MulNoSMT, IT (Binop (Div, IT (Sym x', _, _), it1), _, _), it2), _, _)
          )
      | Binop
          ( EQ,
            IT (Sym x, x_bt, x_loc),
            IT
              (Binop (Mul, IT (Binop (DivNoSMT, IT (Sym x', _, _), it1), _, _), it2), _, _)
          )
      | Binop
          ( EQ,
            IT (Sym x, x_bt, x_loc),
            IT
              ( Binop (MulNoSMT, IT (Binop (DivNoSMT, IT (Sym x', _, _), it1), _, _), it2),
                _,
                _ ) )
        when Sym.equal x x' && IT.equal it1 it2 ->
        IT.eq_
          (IT.mod_ (IT.sym_ (x, x_bt, x_loc), it1) loc, IT.num_lit_ Z.zero x_bt loc)
          loc
      | (Binop (Min, it1, it2) | Binop (Max, it1, it2)) when IT.equal it1 it2 -> it1
      | Binop (Min, it1, it2) ->
        (match (IT.is_bits_const it1, IT.is_bits_const it2) with
         | Some (_, n1), Some (_, n2) -> IT.num_lit_ (Z.min n1 n2) bt loc
         | Some ((sgn, sz), n), _ when Z.equal n (fst (BT.bits_range (sgn, sz))) -> it1
         | _, Some ((sgn, sz), n) when Z.equal n (fst (BT.bits_range (sgn, sz))) -> it2
         | Some ((sgn, sz), n), _ when Z.equal n (snd (BT.bits_range (sgn, sz))) -> it2
         | _, Some ((sgn, sz), n) when Z.equal n (snd (BT.bits_range (sgn, sz))) -> it1
         | _ -> it)
      | Binop (Max, it1, it2) ->
        (match (IT.is_bits_const it1, IT.is_bits_const it2) with
         | Some (_, n1), Some (_, n2) -> IT.num_lit_ (Z.max n1 n2) bt loc
         | Some ((sgn, sz), n), _ when Z.equal n (snd (BT.bits_range (sgn, sz))) -> it1
         | _, Some ((sgn, sz), n) when Z.equal n (snd (BT.bits_range (sgn, sz))) -> it2
         | Some ((sgn, sz), n), _ when Z.equal n (fst (BT.bits_range (sgn, sz))) -> it2
         | _, Some ((sgn, sz), n) when Z.equal n (fst (BT.bits_range (sgn, sz))) -> it1
         | _ -> it)
      | _ -> it
    in
    IT.map_term_post aux it


  let simplify_lc (lc : LC.t) : LC.t =
    match lc with
    | T it -> T (simplify_it it)
    | Forall ((i, i_bt), IT (Binop (Implies, it_perm, it_body), _, loc_implies)) ->
      let it_perm = simplify_it it_perm in
      let it_body = simplify_it it_body in
      if IT.is_false it_perm || IT.is_true it_body then
        LC.T (IT.bool_ true loc_implies)
      else
        LC.Forall ((i, i_bt), IT.arith_binop Implies (it_perm, it_body) loc_implies)
    | _ -> failwith __LOC__


  let transform (gt : GT.t) : GT.t =
    let aux (gt : GT.t) : GT.t =
      let (GT (gt_, bt, loc)) = gt in
      match gt_ with
      | Call (fsym, iargs) -> GT.call_ (fsym, List.map_snd simplify_it iargs) bt loc
      | Asgn ((it_addr, sct), it_val, gt') ->
        GT.asgn_ ((simplify_it it_addr, sct), simplify_it it_val, gt') loc
      | Return it -> GT.return_ (simplify_it it) loc
      | Assert (lc, gt') -> GT.assert_ (simplify_lc lc, gt') loc
      | ITE (it_if, gt_then, gt_else) -> GT.ite_ (simplify_it it_if, gt_then, gt_else) loc
      | Map ((i, i_bt, it_perm), gt') -> GT.map_ ((i, i_bt, simplify_it it_perm), gt') loc
      | _ -> gt
    in
    GT.map_gen_post aux gt


  let pass = { name; transform }
end

(** This pass removes unused variables *)
module RemoveUnused = struct
  let name = "remove_unused"

  let transform (gt : GT.t) : GT.t =
    let aux (gt : GT.t) : GT.t =
      let (GT (gt_, _, _)) = gt in
      match gt_ with
      | Let (_, (x, gt_inner), gt_rest)
        when GA.is_pure gt_inner && not (Sym.Set.mem x (GT.free_vars gt_rest)) ->
        gt_rest
      | Assert (T it, gt_rest) when IT.is_true it -> gt_rest
      | _ -> gt
    in
    GT.map_gen_post aux gt


  let passes = [ { name; transform } ]
end

(** This pass pulls asserts and assignments
    closer to the relevant variables *)
module Reordering = struct
  let name = "reordering"

  module SymGraph = Graph.Persistent.Digraph.Concrete (Sym)

  let get_variable_ordering
        (_rec_fsyms : Sym.Set.t)
        (iargs : Sym.Set.t)
        (stmts : GS.t list)
    : Sym.t list
    =
    let module Oper = Graph.Oper.P (SymGraph) in
    (* Insert edges x <- y_1, ..., y_n when x = f(y_1, ..., y_n) *)
    let rec consider_equalities (stmts : GS.t list) : SymGraph.t =
      match stmts with
      | Let (_, (x, _)) :: stmts' -> SymGraph.add_vertex (consider_equalities stmts') x
      | Assert (T (IT (Binop (EQ, IT (Sym x, _, _), it), _, _))) :: stmts' ->
        let g = consider_equalities stmts' in
        let g' =
          List.fold_left
            (fun g' y ->
               if Sym.Set.mem y iargs || Sym.equal x y then
                 g'
               else
                 SymGraph.add_edge_e g' (y, x))
            g
            (it |> IT.free_vars |> Sym.Set.to_seq |> List.of_seq)
        in
        g'
      | Assert (T (IT (Binop (EQ, it, IT (Sym x, _, _)), _, _))) :: stmts' ->
        let g = consider_equalities stmts' in
        Seq.fold_left
          (fun g' y ->
             if Sym.Set.mem y iargs || Sym.equal x y then
               g'
             else
               SymGraph.add_edge_e g' (y, x))
          g
          (it |> IT.free_vars |> Sym.Set.to_seq)
      | _ :: stmts' -> consider_equalities stmts'
      | [] -> SymGraph.empty
    in
    (* Put calls before local variables they constrain *)
    let rec consider_constrained_calls
              (from_calls : Sym.Set.t)
              (g : SymGraph.t)
              (stmts : GS.t list)
      : SymGraph.t
      =
      match stmts with
      | Let (_, (x, gt)) :: stmts' when GT.contains_call gt ->
        consider_constrained_calls (Sym.Set.add x from_calls) g stmts'
      | Asgn _ :: stmts' | Let _ :: stmts' ->
        consider_constrained_calls from_calls g stmts'
      | Assert lc :: stmts' ->
        let g = consider_constrained_calls from_calls g stmts' in
        let free_vars = LC.free_vars lc in
        let call_vars = Sym.Set.inter free_vars from_calls in
        let non_call_vars = Sym.Set.diff free_vars from_calls in
        let add_from_call (x : Sym.t) (g : SymGraph.t) : SymGraph.t =
          Sym.Set.fold (fun y g' -> SymGraph.add_edge g' y x) call_vars g
        in
        Sym.Set.fold add_from_call non_call_vars g
      | [] -> g
    in
    (* Describes logical dependencies where [x <- y] means that [x] depends on [y] *)
    let collect_constraints (stmts : GS.t list) : SymGraph.t =
      let g = consider_equalities stmts in
      let g' = Oper.transitive_closure g in
      let g'' = consider_constrained_calls Sym.Set.empty g' stmts in
      let g''' = Oper.transitive_closure g'' in
      assert (not (SymGraph.fold_edges (fun x y acc -> Sym.equal x y || acc) g''' false));
      g'''
    in
    (* Describes data dependencies where [x <- y] means that [x] depends on [y] *)
    let collect_dependencies (stmts : GS.t list) : SymGraph.t =
      let rec aux (stmts : GS.t list) : SymGraph.t =
        match stmts with
        | Let (_, (x, gt)) :: stmts' ->
          let g = SymGraph.add_vertex (aux stmts') x in
          Sym.Set.fold
            (fun y g' ->
               if Sym.Set.mem y iargs then
                 g'
               else
                 SymGraph.add_edge g' y x)
            (GT.free_vars gt)
            g
        | _ :: stmts' -> aux stmts'
        | [] -> SymGraph.empty
      in
      stmts |> aux |> Oper.transitive_closure
    in
    let g_c = collect_constraints stmts in
    let g_d = collect_dependencies stmts in
    let orig_order =
      List.filter_map (function GS.Let (_, (x, _)) -> Some x | _ -> None) stmts
    in
    (* Get variables that should be generated before [x], in the order they appear *)
    let get_needs (x : Sym.t) (ys : Sym.t list) : Sym.t list =
      let syms_c =
        SymGraph.fold_pred
          (fun y syms -> if List.mem Sym.equal y ys then syms else Sym.Set.add y syms)
          g_c
          x
          Sym.Set.empty
      in
      let syms =
        Sym.Set.fold
          (fun z acc ->
             Sym.Set.union
               acc
               (SymGraph.fold_pred
                  (fun y syms' ->
                     if List.mem Sym.equal y ys then syms' else Sym.Set.add y syms')
                  g_d
                  z
                  Sym.Set.empty))
          syms_c
          syms_c
      in
      orig_order |> List.filter (fun x -> Sym.Set.mem x syms)
    in
    let new_order : Sym.t list -> Sym.t list =
      List.fold_left
        (fun acc y ->
           if List.mem Sym.equal y acc then
             acc
           else (
             let zs = get_needs y acc in
             if List.is_empty zs then
               acc @ [ y ]
             else
               acc @ zs @ [ y ]))
        []
    in
    let rec loop (ys : Sym.t list) : Sym.t list =
      let old_ys = ys in
      let new_ys = new_order ys in
      if List.equal Sym.equal old_ys new_ys then new_ys else loop new_ys
    in
    loop orig_order


  let get_statement_ordering
        (rec_fsyms : Sym.Set.t)
        (iargs : Sym.Set.t)
        (stmts : GS.t list)
    : GS.t list
    =
    let rec loop (vars : Sym.Set.t) (syms : Sym.t list) (stmts : GS.t list) : GS.t list =
      let res, stmts' =
        List.partition
          (fun (stmt : GS.t) ->
             match stmt with
             | Asgn ((it_addr, _sct), it_val) ->
               Sym.Set.subset (IT.free_vars_list [ it_addr; it_val ]) vars
             | Assert lc -> Sym.Set.subset (LC.free_vars lc) vars
             | _ -> false)
          stmts
      in
      match syms with
      | sym :: syms' ->
        let res', stmts'' =
          List.partition
            (fun (stmt : GS.t) ->
               match stmt with Let (_, (x, _)) -> Sym.equal x sym | _ -> false)
            stmts'
        in
        res @ res' @ loop (Sym.Set.add sym vars) syms' stmts''
      | [] ->
        if List.non_empty stmts' then
          print_endline
            (match stmts' with
             | [ Assert lc ] ->
               Pp.(
                 LC.free_vars lc
                 |> Sym.Set.to_seq
                 |> List.of_seq
                 |> separate_map (comma ^^ space) Sym.pp
                 |> plain)
             | _ -> "ss");
        res
    in
    let syms = get_variable_ordering rec_fsyms iargs stmts in
    loop iargs syms stmts


  let reorder (rec_fsyms : Sym.Set.t) (iargs : Sym.Set.t) (gt : GT.t) : GT.t =
    let stmts, gt_last = GS.stmts_of_gt gt in
    let stmts = get_statement_ordering rec_fsyms iargs stmts in
    GS.gt_of_stmts stmts gt_last


  let transform (gtx : GC.t) (gd : GD.t) : GD.t =
    let rec_fsyms =
      gtx
      |> List.map snd
      |> List.filter_map (fun (gd' : GD.t) ->
        if gd'.recursive then Some gd'.name else None)
      |> Sym.Set.of_list
    in
    let rec aux (iargs : Sym.Set.t) (gt : GT.t) : GT.t =
      let rec loop (iargs : Sym.Set.t) (gt : GT.t) : GT.t =
        let (GT (gt_, _bt, loc)) = gt in
        match gt_ with
        | Arbitrary | Uniform | Alloc | Call _ | Return _ -> gt
        | Pick wgts -> GT.pick_ (List.map_snd (aux iargs) wgts) loc
        | Asgn ((it_addr, sct), it_val, gt_rest) ->
          GT.asgn_ ((it_addr, sct), it_val, loop iargs gt_rest) loc
        | Let (backtracks, (x, gt'), gt_rest) ->
          let iargs = Sym.Set.add x iargs in
          GT.let_ (backtracks, (x, (aux iargs) gt'), loop iargs gt_rest) loc
        | Assert (lc, gt_rest) -> GT.assert_ (lc, loop iargs gt_rest) loc
        | ITE (it_if, gt_then, gt_else) ->
          GT.ite_ (it_if, aux iargs gt_then, aux iargs gt_else) loc
        | Map ((i_sym, i_bt, it_perm), gt_inner) ->
          GT.map_ ((i_sym, i_bt, it_perm), aux (Sym.Set.add i_sym iargs) gt_inner) loc
      in
      gt |> reorder rec_fsyms iargs |> loop iargs
    in
    let iargs = gd.iargs |> List.map fst |> Sym.Set.of_list in
    { gd with body = aux iargs gd.body }
end

module ConstraintPropagation = struct
  open Interval

  module IntRep = struct
    type t =
      { mult : Z.t;
        intervals : Intervals.t
      }
    [@@deriving eq, ord]

    let of_ (mult : Z.t) (intervals : Intervals.t) : t =
      let intervals =
        if Intervals.is_empty intervals then
          intervals
        else
          let open Z in
          let min = Option.get (Intervals.minimum intervals) in
          let min' = min / mult * mult in
          let max' = Z.succ (Option.get (Intervals.maximum intervals)) in
          let max =
            ((max' / mult) + if Z.equal (max' mod mult) Z.zero then Z.zero else Z.one)
            * mult
          in
          let mult_interval = Interval.range (Z.max min min') (Z.min max max') in
          Intervals.intersect (Intervals.of_interval mult_interval) intervals
      in
      { mult; intervals }


    let rec of_bt (bt : BT.t) : t option =
      match bt with
      | Loc () -> of_bt Memory.uintptr_bt
      | Bits (sgn, bits) ->
        let to_interval =
          match sgn with Signed -> Interval.sint | Unsigned -> Interval.uint
        in
        let interval = to_interval bits in
        Some (of_ Z.one (Intervals.of_interval interval))
      | _ -> None


    let of_mult (mult : Z.t) : t =
      { mult; intervals = Intervals.of_interval Interval.int }


    let of_intervals (intervals : Intervals.t) : t = { mult = Z.one; intervals }

    let of_interval (interval : Interval.t) : t =
      of_intervals (Intervals.of_interval interval)


    let const (n : Z.t) : t = of_interval (Interval.const n)

    let empty () : t =
      let i =
        Intervals.intersect
          (Intervals.of_interval (Interval.const Z.zero))
          (Intervals.of_interval (Interval.const Z.one))
      in
      (* So we know if something changes in [Intervals] *)
      assert (Intervals.is_empty i);
      of_intervals i


    let ne (n : Z.t) : t =
      of_intervals (Intervals.complement (Intervals.of_interval (Interval.const n)))


    let lt (n : Z.t) : t = of_interval (Interval.lt n)

    let leq (n : Z.t) : t = of_interval (Interval.leq n)

    let gt (n : Z.t) : t = of_interval (Interval.gt n)

    let geq (n : Z.t) : t = of_interval (Interval.geq n)

    let intersect ({ mult = m1; intervals = i1 } : t) ({ mult = m2; intervals = i2 } : t)
      : t
      =
      let mult = Z.lcm m1 m2 in
      let intervals = Intervals.intersect i1 i2 in
      of_ mult intervals


    let is_const (r : t) : Z.t option = Intervals.is_const r.intervals

    let is_empty (r : t) : bool = Intervals.is_empty r.intervals

    let minimum (r : t) : Z.t option = Intervals.minimum r.intervals

    let maximum (r : t) : Z.t option = Intervals.maximum r.intervals
  end

  module Domain = struct
    type t = Int of IntRep.t [@@deriving eq, ord]

    let hash = Hashtbl.hash

    let rec of_it (it : IT.t) : (bool * (Sym.t * t)) option =
      let (IT (it_, _, _)) = it in
      let open Option in
      match it_ with
      | Binop (op, IT (Sym x, x_bt, _), IT (Const (Bits (_, n)), _, _))
      | Binop
          (op, IT (Cast (_, IT (Sym x, x_bt, _)), _, _), IT (Const (Bits (_, n)), _, _))
        ->
        let@ bt_rep = IntRep.of_bt x_bt in
        (match op with
         | EQ -> Some (true, (x, Int (IntRep.intersect bt_rep (IntRep.const n))))
         | LT -> Some (true, (x, Int (IntRep.intersect bt_rep (IntRep.lt n))))
         | LE -> Some (true, (x, Int (IntRep.intersect bt_rep (IntRep.leq n))))
         | _ -> None)
      | Binop (op, IT (Const (Bits (_, n)), _, _), IT (Sym x, x_bt, _))
      | Binop
          (op, IT (Const (Bits (_, n)), _, _), IT (Cast (_, IT (Sym x, x_bt, _)), _, _))
        ->
        let@ bt_rep = IntRep.of_bt x_bt in
        (match op with
         | EQ -> Some (true, (x, Int (IntRep.intersect bt_rep (IntRep.const n))))
         | LT -> Some (true, (x, Int (IntRep.intersect bt_rep (IntRep.gt n))))
         | LE -> Some (true, (x, Int (IntRep.intersect bt_rep (IntRep.geq n))))
         | _ -> None)
      | Binop
          ( op,
            IT (Const (Bits (_, n)), _, _),
            IT (Binop (Add, IT (Sym x, x_bt, _), IT (Const (Bits (_, m)), _, _)), _, _) )
      | Binop
          ( op,
            IT (Const (Bits (_, n)), _, _),
            IT (Binop (Add, IT (Const (Bits (_, m)), _, _), IT (Sym x, x_bt, _)), _, _) )
      | Binop
          ( op,
            IT (Const (Bits (_, n)), _, _),
            IT
              ( Binop
                  ( Add,
                    IT (Cast (_, IT (Sym x, x_bt, _)), _, _),
                    IT (Const (Bits (_, m)), _, _) ),
                _,
                _ ) )
      | Binop
          ( op,
            IT (Const (Bits (_, n)), _, _),
            IT
              ( Binop
                  ( Add,
                    IT (Const (Bits (_, m)), _, _),
                    IT (Cast (_, IT (Sym x, x_bt, _)), _, _) ),
                _,
                _ ) )
        when Z.equal m Z.one ->
        let@ bt_rep = IntRep.of_bt x_bt in
        (match op with
         | LT -> Some (true, (x, Int (IntRep.intersect bt_rep (IntRep.geq n))))
         | _ -> None)
      | Binop
          ( op,
            IT (Binop (Sub, IT (Sym x, x_bt, _), IT (Const (Bits (_, m)), _, _)), _, _),
            IT (Const (Bits (_, n)), _, _) )
      | Binop
          ( op,
            IT
              ( Binop
                  ( Sub,
                    IT (Cast (_, IT (Sym x, x_bt, _)), _, _),
                    IT (Const (Bits (_, m)), _, _) ),
                _,
                _ ),
            IT (Const (Bits (_, n)), _, _) )
        when Z.equal m Z.one ->
        let@ bt_rep = IntRep.of_bt x_bt in
        (match op with
         | LT -> Some (true, (x, Int (IntRep.intersect bt_rep (IntRep.leq n))))
         | _ -> None)
      | Binop
          ( op,
            IT (Const (Bits (_, n)), _, _),
            IT (Binop (Sub, IT (Sym x, x_bt, _), IT (Const (Bits (_, m)), _, _)), _, _) )
        when Z.equal m Z.one ->
        let@ bt_rep = IntRep.of_bt x_bt in
        (match op with
         | LE -> Some (true, (x, Int (IntRep.intersect bt_rep (IntRep.gt n))))
         | _ -> None)
      | Binop
          ( op,
            IT (Binop (Add, IT (Sym x, bt, _), IT (Sym y, _, _)), _, _),
            IT (Const (Bits (_, n)), _, _) )
      | Binop
          ( op,
            IT
              ( Binop
                  ( Add,
                    IT (Cast (_, IT (Sym x, bt, _)), _, _),
                    IT (Cast (_, IT (Sym y, _, _)), _, _) ),
                _,
                _ ),
            IT (Const (Bits (_, n)), _, _) )
        when Sym.equal x y ->
        let loc = Locations.other __LOC__ in
        (match op with
         | EQ | LT | LE ->
           of_it
             (IT.arith_binop
                op
                (IT.sym_ (x, bt, loc), IT.num_lit_ (Z.div n (Z.of_int 2)) bt loc)
                loc)
         | _ -> None)
      (* START FIXME: Simplify should do this *)
      | Binop
          ( op,
            IT (Const (Bits ((sgn, sz), n)), bt, _),
            IT (Binop (Sub, it', IT (Const (Bits (_, m)), _, _)), _, _) )
        when BT.fits_range (sgn, sz) (Z.add n m) ->
        let loc = Locations.other __LOC__ in
        (match op with
         | EQ | LT | LE ->
           of_it (IT.arith_binop op (IT.num_lit_ (Z.add n m) bt loc, it') loc)
         | _ -> None)
      | Binop
          ( op,
            IT (Const (Bits ((sgn, sz), n)), bt, _),
            IT (Binop (Add, it', IT (Const (Bits (_, m)), _, _)), _, _) )
        when BT.fits_range (sgn, sz) (Z.sub n m) ->
        let loc = Locations.other __LOC__ in
        (match op with
         | EQ | LT | LE ->
           of_it (IT.arith_binop op (IT.num_lit_ (Z.sub n m) bt loc, it') loc)
         | _ -> None)
      | Binop
          ( op,
            IT (Binop (Sub, it', IT (Const (Bits (_, m)), _, _)), _, _),
            IT (Const (Bits ((sgn, sz), n)), bt, _) )
        when BT.fits_range (sgn, sz) (Z.add n m) ->
        let loc = Locations.other __LOC__ in
        (match op with
         | EQ | LT | LE ->
           of_it (IT.arith_binop op (it', IT.num_lit_ (Z.add n m) bt loc) loc)
         | _ -> None)
      | Binop
          ( op,
            IT (Binop (Add, it', IT (Const (Bits (_, m)), _, _)), _, _),
            IT (Const (Bits ((sgn, sz), n)), bt, _) )
        when BT.fits_range (sgn, sz) (Z.add n m) ->
        let loc = Locations.other __LOC__ in
        (match op with
         | EQ | LT | LE ->
           of_it (IT.arith_binop op (it', IT.num_lit_ (Z.sub n m) bt loc) loc)
         | _ -> None)
      | Binop (op, IT (Const (Bits (_, n)), bt, _), IT (Binop (Mul, it1, it2), _, _))
      | Binop
          ( op,
            IT (Cast (_, IT (Const (Bits (_, n)), _, _)), bt, _),
            IT (Binop (Mul, it1, it2), _, _) )
      | Binop
          ( op,
            IT (Cast (_, IT (Const (Bits (_, n)), _, _)), bt, _),
            IT (Cast (_, IT (Binop (Mul, it1, it2), _, _)), _, _) ) ->
        (match (it1, it2) with
         | ( (IT (Cast (Bits (sgn, sz), IT (Sym _, bt', _)), _, _) as it'),
             IT (Const (Bits (_, m)), _, _) )
         | ( (IT (Cast (Bits (sgn, sz), IT (Sym _, bt', _)), _, _) as it'),
             IT (Cast (_, IT (Const (Bits (_, m)), _, _)), _, _) )
         | ( IT (Const (Bits (_, m)), _, _),
             (IT (Cast (Bits (sgn, sz), IT (Sym _, bt', _)), _, _) as it') )
         | ( IT (Cast (_, IT (Const (Bits (_, m)), _, _)), _, _),
             (IT (Cast (Bits (sgn, sz), IT (Sym _, bt', _)), _, _) as it') ) ->
           let loc = Locations.other __LOC__ in
           (match BT.is_bits_bt bt' with
            | Some (sgn', sz')
              when Z.geq
                     (snd (BT.bits_range (sgn, sz)))
                     (Z.pow (snd (BT.bits_range (sgn', sz'))) 2) ->
              (match op with
               | EQ when Z.divisible n m ->
                 of_it (IT.eq_ (IT.num_lit_ (Z.div n m) bt loc, it') loc)
               | LE when Z.geq n Z.zero && Z.gt m Z.zero ->
                 of_it (IT.le_ (IT.num_lit_ (Z.div n m) bt loc, it') loc)
               | LE when Z.leq n Z.zero && Z.gt m Z.zero ->
                 of_it
                   (IT.le_
                      (IT.num_lit_ (Z.div (Z.add n (Z.sub m Z.one)) m) bt loc, it')
                      loc)
               | LT when Z.geq n Z.zero && Z.gt m Z.zero ->
                 of_it (IT.lt_ (IT.num_lit_ (Z.div n m) bt loc, it') loc)
               | LT when Z.leq n Z.zero && Z.gt m Z.zero ->
                 of_it
                   (IT.lt_
                      (IT.num_lit_ (Z.div (Z.add n (Z.sub m Z.one)) m) bt loc, it')
                      loc)
               | _ -> None)
            | _ -> None)
         | _ -> None)
      | Binop (op, IT (Binop (Mul, it1, it2), _, _), IT (Const (Bits (_, n)), bt, _))
      | Binop
          ( op,
            IT (Binop (Mul, it1, it2), _, _),
            IT (Cast (_, IT (Const (Bits (_, n)), _, _)), bt, _) )
      | Binop
          ( op,
            IT (Cast (_, IT (Binop (Mul, it1, it2), _, _)), _, _),
            IT (Cast (_, IT (Const (Bits (_, n)), _, _)), bt, _) ) ->
        (match (it1, it2) with
         | ( (IT (Cast (Bits (sgn, sz), IT (Sym _, bt', _)), _, _) as it'),
             IT (Const (Bits (_, m)), _, _) )
         | ( (IT (Cast (Bits (sgn, sz), IT (Sym _, bt', _)), _, _) as it'),
             IT (Cast (_, IT (Const (Bits (_, m)), _, _)), _, _) )
         | ( IT (Const (Bits (_, m)), _, _),
             (IT (Cast (Bits (sgn, sz), IT (Sym _, bt', _)), _, _) as it') )
         | ( IT (Cast (_, IT (Const (Bits (_, m)), _, _)), _, _),
             (IT (Cast (Bits (sgn, sz), IT (Sym _, bt', _)), _, _) as it') ) ->
           let loc = Locations.other __LOC__ in
           (match BT.is_bits_bt bt' with
            | Some (sgn', sz')
              when Z.geq
                     (snd (BT.bits_range (sgn, sz)))
                     (Z.pow (snd (BT.bits_range (sgn', sz'))) 2) ->
              (match op with
               | EQ when Z.divisible n m ->
                 of_it (IT.eq_ (IT.num_lit_ (Z.div n m) bt loc, it') loc)
               | LE when Z.geq n Z.zero && Z.gt m Z.zero ->
                 of_it (IT.le_ (it', IT.num_lit_ (Z.div n m) bt loc) loc)
               | LE when Z.leq n Z.zero && Z.gt m Z.zero ->
                 of_it
                   (IT.le_
                      (it', IT.num_lit_ (Z.div (Z.add n (Z.sub m Z.one)) m) bt loc)
                      loc)
               | LT when Z.geq n Z.zero && Z.gt m Z.zero ->
                 of_it (IT.lt_ (it', IT.num_lit_ (Z.div n m) bt loc) loc)
               | LT when Z.leq n Z.zero && Z.gt m Z.zero ->
                 of_it
                   (IT.lt_
                      (it', IT.num_lit_ (Z.div (Z.add n (Z.sub m Z.one)) m) bt loc)
                      loc)
               | _ -> None)
            | _ -> None)
         | _ -> None)
      (* END Simplify stuff*)
      | Unop
          (Not, IT (Binop (EQ, IT (Sym x, x_bt, _), IT (Const (Bits (_, n)), _, _)), _, _))
      | Unop
          (Not, IT (Binop (EQ, IT (Const (Bits (_, n)), _, _), IT (Sym x, x_bt, _)), _, _))
        ->
        let@ bt_rep = IntRep.of_bt x_bt in
        Some (false, (x, Int (IntRep.intersect bt_rep (IntRep.ne n))))
      | Binop
          ( EQ,
            IT (Binop (Mod, IT (Sym x, x_bt, _), IT (Const (Bits (_, n)), _, _)), _, _),
            IT (Const (Bits (_, m)), _, _) )
      | Binop
          ( EQ,
            IT (Const (Bits (_, m)), _, _),
            IT (Binop (Mod, IT (Sym x, x_bt, _), IT (Const (Bits (_, n)), _, _)), _, _) )
      | Binop
          ( EQ,
            IT
              ( Binop
                  ( Mod,
                    IT (Cast (_, IT (Sym x, x_bt, _)), _, _),
                    IT (Const (Bits (_, n)), _, _) ),
                _,
                _ ),
            IT (Const (Bits (_, m)), _, _) )
      | Binop
          ( EQ,
            IT (Const (Bits (_, m)), _, _),
            IT
              ( Binop
                  ( Mod,
                    IT (Cast (_, IT (Sym x, x_bt, _)), _, _),
                    IT (Const (Bits (_, n)), _, _) ),
                _,
                _ ) )
        when Z.equal m Z.zero
             &&
             let sgn, sz =
               Option.get
                 (BT.is_bits_bt
                    (if BT.equal x_bt (Loc ()) then
                       Memory.uintptr_bt
                     else
                       x_bt))
             in
             BT.fits_range (sgn, sz) n ->
        let@ bt_rep = IntRep.of_bt x_bt in
        Some (true, (x, Int (IntRep.intersect bt_rep (IntRep.of_mult n))))
      | _ -> None


    let intersect (Int r1) (Int r2) : t = Int (IntRep.intersect r1 r2)

    let is_const (Int r) = IntRep.is_const r

    let to_stmts (x : Sym.t) (bt : BT.t) (Int r : t) : GS.t list =
      let loc = Locations.other __LOC__ in
      let lit n =
        if BT.equal bt (Loc ()) then
          IT.pointer_ ~alloc_id:Z.zero ~addr:n loc
        else
          IT.num_lit_ n bt loc
      in
      let le (n, m) =
        if BT.equal bt (Loc ()) then IT.lePointer_ (n, m) loc else IT.le_ (n, m) loc
      in
      let aux (sgn : BT.sign) (sz : int) : GS.t list =
        let min_bt, max_bt = BT.bits_range (sgn, sz) in
        if IntRep.is_empty r then
          [ GS.Assert (T (IT.bool_ false loc)) ]
        else (
          let min, max = (Option.get (IntRep.minimum r), Option.get (IntRep.maximum r)) in
          let stmts_range =
            if Z.equal min max then
              [ GS.Assert (T (IT.eq_ (IT.sym_ (x, bt, loc), lit min) loc)) ]
            else (
              let stmt_min =
                if Z.lt min_bt min then
                  [ GS.Assert (LC.T (le (lit min, IT.sym_ (x, bt, loc)))) ]
                else
                  []
              in
              let stmt_max =
                if Z.lt max max_bt then
                  [ GS.Assert (LC.T (le (IT.sym_ (x, bt, loc), lit max))) ]
                else
                  []
              in
              stmt_min @ stmt_max)
          in
          let stmt_mult =
            if Z.equal r.mult Z.one then
              []
            else
              [ GS.Assert
                  (LC.T
                     (IT.eq_
                        ( IT.mod_
                            (if BT.equal bt (Loc ()) then
                               ( IT.cast_ Memory.uintptr_bt (IT.sym_ (x, bt, loc)) loc,
                                 IT.num_lit_ r.mult Memory.uintptr_bt loc )
                             else
                               (IT.sym_ (x, bt, loc), lit r.mult))
                            loc,
                          IT.num_lit_
                            Z.zero
                            (if BT.equal bt (Loc ()) then Memory.uintptr_bt else bt)
                            loc )
                        loc))
              ]
          in
          stmt_mult @ stmts_range)
      in
      match bt with
      | Loc () ->
        let sgn, sz = Option.get (BT.is_bits_bt Memory.uintptr_bt) in
        aux sgn sz
      | Bits (sgn, sz) -> aux sgn sz
      | _ -> failwith (Pp.plain (BT.pp bt) ^ " @ " ^ __LOC__)
  end

  module Constraint = struct
    type t =
      | Eq
      | Ne
      | Lt
      | Le
      | Invalid
    [@@deriving eq, ord]

    let default = Invalid

    let of_it (it : IT.t) : (Sym.t * t * Sym.t) option =
      let (IT (it_, _, _)) = it in
      match it_ with
      | Binop (op, IT (Sym x, _, _), IT (Sym y, _, _)) ->
        (match op with
         | EQ -> Some (x, Eq, y)
         | LT -> Some (x, Lt, y)
         | LE -> Some (x, Le, y)
         | _ -> None)
      | Binop
          ( op,
            IT (Sym x, _, _),
            IT (Binop (Add, IT (Sym y, _, _), IT (Const (Bits (_, n)), _, _)), _, _) )
      | Binop
          ( op,
            IT (Sym x, _, _),
            IT (Binop (Add, IT (Const (Bits (_, n)), _, _), IT (Sym y, _, _)), _, _) ) ->
        (match op with
         | LT -> if Z.equal n Z.one then Some (x, Le, y) else None
         | _ -> None)
      | Binop
          ( op,
            IT (Binop (Sub, IT (Sym x, _, _), IT (Const (Bits (_, n)), _, _)), _, _),
            IT (Sym y, _, _) ) ->
        (match op with
         | LT -> if Z.equal n Z.one then Some (x, Le, y) else None
         | _ -> None)
      | Unop (Not, IT (Binop (EQ, IT (Sym x, _, _), IT (Sym y, _, _)), _, _)) ->
        Some (x, Ne, y)
      | _ -> None


    let intersect (c1 : t) (c2 : t) : t =
      match (c1, c2) with
      | Eq, Eq | Ne, Ne | Lt, Lt | Le, Le -> c1
      | Eq, Le | Le, Eq -> Eq
      | Lt, Le | Le, Lt | Lt, Ne | Ne, Lt -> Lt
      | Eq, Ne | Ne, Eq | Eq, Lt | Lt, Eq | Le, Ne | Ne, Le | Invalid, _ | _, Invalid ->
        Invalid
  end

  module ConstraintNetwork = struct
    open struct
      module G = Graph.Persistent.Digraph.ConcreteLabeled (Sym) (Constraint)
    end

    type t = Domain.t Sym.Map.t * G.t

    let empty = (Sym.Map.empty, G.empty)

    let variables ((ds, _) : t) : Domain.t Sym.Map.t = ds

    let constraints ((_, g) : t) : (Sym.t * Constraint.t * Sym.t) list =
      G.fold_edges_e (fun edge edges -> edge :: edges) g []


    let add_variable (x : Sym.t) (d : Domain.t) ((ds, g) : t) : t =
      ( Sym.Map.update
          x
          (fun od ->
             match od with Some d' -> Some (Domain.intersect d d') | None -> Some d)
          ds,
        G.add_vertex g x )


    let add_constraint (c : Constraint.t) (x : Sym.t) (y : Sym.t) ((ds, g) : t) : t =
      let g =
        match G.find_all_edges g x y with
        | [ (x', c', y') ] ->
          G.add_edge_e (G.remove_edge_e g (x', c', y')) (x, Constraint.intersect c c', y)
        | [] -> G.add_edge_e g (x, c, y)
        | _ -> failwith __LOC__
      in
      (ds, g)


    let domain (x : Sym.t) ((ds, _) : t) : Domain.t = Sym.Map.find x ds

    let domain_opt (x : Sym.t) ((ds, _) : t) : Domain.t option = Sym.Map.find_opt x ds

    let related_constraints ((_, g) : t) (x : Sym.t) : (Sym.t * Constraint.t * Sym.t) list
      =
      G.fold_edges_e
        (fun (y, c, z) acc ->
           if Sym.equal x y || Sym.equal x z then (y, c, z) :: acc else acc)
        g
        []
  end

  let construct_network (stmts : GS.t list) : GS.t list * ConstraintNetwork.t =
    let rec aux (stmts : GS.t list) : GS.t list * ConstraintNetwork.t =
      match stmts with
      | (Asgn _ as stmt) :: stmts'
      | (Let _ as stmt) :: stmts'
      | (Assert (Forall _) as stmt) :: stmts' ->
        let stmts', network = aux stmts' in
        (stmt :: stmts', network)
      | (Assert (T it) as stmt) :: stmts' ->
        let stmts', network = aux stmts' in
        (match (Domain.of_it it, Constraint.of_it it) with
         | Some (redundant, (x, d)), None ->
           (* We don't include these constraints, as we will add refined ones later *)
           if redundant then
             (stmts', ConstraintNetwork.add_variable x d network)
           else
             (stmt :: stmts', ConstraintNetwork.add_variable x d network)
         | None, Some (x, c, y) ->
           let xbts = IT.free_vars_bts it in
           let network =
             ConstraintNetwork.add_variable
               x
               (Int (Option.get (IntRep.of_bt (Sym.Map.find x xbts))))
               network
           in
           let network =
             ConstraintNetwork.add_variable
               y
               (Int (Option.get (IntRep.of_bt (Sym.Map.find y xbts))))
               network
           in
           (stmt :: stmts', ConstraintNetwork.add_constraint c x y network)
         | None, None -> (stmt :: stmts', network)
         | Some _, Some _ -> failwith __LOC__)
      | [] -> ([], ConstraintNetwork.empty)
    in
    aux stmts


  let revise (c : Constraint.t) (Int r1 : Domain.t) (Int r2 : Domain.t)
    : Domain.t * Domain.t
    =
    match c with
    | Eq ->
      let r : Domain.t = Int (IntRep.intersect r1 r2) in
      (r, r)
    | Ne ->
      let r1' : Domain.t =
        match IntRep.is_const r2 with
        | Some n ->
          Int
            (IntRep.of_
               r1.mult
               (Intervals.intersect
                  r1.intervals
                  (Intervals.complement (Intervals.of_interval (Interval.const n)))))
        | None -> Int r1
      in
      let r2' : Domain.t =
        match IntRep.is_const r1 with
        | Some n ->
          Int
            (IntRep.of_
               r2.mult
               (Intervals.intersect
                  r2.intervals
                  (Intervals.complement (Intervals.of_interval (Interval.const n)))))
        | None -> Int r2
      in
      (r1', r2')
    | Lt ->
      let r1' : Domain.t =
        Int
          (if IntRep.is_empty r2 then
             r2
           else
             IntRep.intersect r1 (IntRep.lt (Option.get (IntRep.maximum r2))))
      in
      let r2' : Domain.t =
        Int
          (if IntRep.is_empty r1 then
             r1
           else
             IntRep.intersect r2 (IntRep.geq (Option.get (IntRep.minimum r1))))
      in
      (r1', r2')
    | Le ->
      let r1' : Domain.t =
        Int
          (if IntRep.is_empty r2 then
             r2
           else
             IntRep.intersect r1 (IntRep.leq (Option.get (IntRep.maximum r2))))
      in
      let r2' : Domain.t =
        Int
          (if IntRep.is_empty r1 then
             r1
           else
             IntRep.intersect r2 (IntRep.gt (Option.get (IntRep.minimum r1))))
      in
      (r1', r2')
    | Invalid -> (Int (IntRep.empty ()), Int (IntRep.empty ()))


  (** AC-3 from https://doi.org/10.1016/0004-3702(77)90007-8 *)
  let ac3 (network : ConstraintNetwork.t) : ConstraintNetwork.t =
    let rec aux
              (network : ConstraintNetwork.t)
              (worklist : (Sym.t * Constraint.t * Sym.t) list)
      : ConstraintNetwork.t
      =
      match worklist with
      | (x, c, y) :: worklist' ->
        let d1 = ConstraintNetwork.domain x network in
        let d2 = ConstraintNetwork.domain y network in
        let d1', d2' = revise c d1 d2 in
        let queue1 =
          if Domain.equal d1 d1' then
            []
          else
            x
            |> ConstraintNetwork.related_constraints network
            |> List.filter (fun (a, _, b) -> not (Sym.equal a y || Sym.equal b y))
        in
        let queue2 =
          if Domain.equal d2 d2' then
            []
          else
            y
            |> ConstraintNetwork.related_constraints network
            |> List.filter (fun (a, _, b) -> not (Sym.equal a y || Sym.equal b y))
        in
        aux
          (ConstraintNetwork.add_variable
             x
             d1'
             (ConstraintNetwork.add_variable y d2' network))
          (queue1 @ queue2 @ worklist')
      | [] -> network
    in
    aux network (ConstraintNetwork.constraints network)


  (** Adds new asserts encoding the domain information *)
  let add_refined_asserts
        (iargs : BT.t Sym.Map.t)
        (network : ConstraintNetwork.t)
        (stmts : GS.t list)
    : GS.t list
    =
    let rec aux (ds : Domain.t Sym.Map.t) (stmts : GS.t list) : GS.t list =
      match stmts with
      | (Let (_, (x, gt)) as stmt) :: stmts' when Sym.Map.mem x ds ->
        (stmt :: Domain.to_stmts x (GT.bt gt) (Sym.Map.find x ds)) @ aux ds stmts'
      | (Asgn _ as stmt) :: stmts'
      | (Let _ as stmt) :: stmts'
      | (Assert _ as stmt) :: stmts' ->
        stmt :: aux ds stmts'
      | [] -> []
    in
    let ds = ConstraintNetwork.variables network in
    let ds_iargs, ds_rest = Sym.Map.partition (fun x _ -> Sym.Map.mem x iargs) ds in
    let stmts_iargs =
      Sym.Map.fold
        (fun x d acc -> Domain.to_stmts x (Sym.Map.find x iargs) d @ acc)
        ds_iargs
        []
    in
    stmts_iargs @ aux ds_rest stmts


  let propagate_constraints (iargs : BT.t Sym.Map.t) (gt : GT.t) : GT.t =
    let stmts, gt_last = GS.stmts_of_gt gt in
    let stmts, network = construct_network stmts in
    let network = ac3 network in
    let stmts = add_refined_asserts iargs network stmts in
    GS.gt_of_stmts stmts gt_last


  let transform (gd : GD.t) : GD.t =
    let rec aux (iargs : BT.t Sym.Map.t) (gt : GT.t) : GT.t =
      let rec loop (iargs : BT.t Sym.Map.t) (gt : GT.t) : GT.t =
        let (GT (gt_, _bt, loc)) = gt in
        match gt_ with
        | Arbitrary | Uniform | Alloc | Call _ | Return _ -> gt
        | Pick wgts -> GT.pick_ (List.map_snd (aux iargs) wgts) loc
        | Asgn ((it_addr, sct), it_val, gt_rest) ->
          GT.asgn_ ((it_addr, sct), it_val, loop iargs gt_rest) loc
        | Let (backtracks, (x, gt'), gt_rest) ->
          GT.let_
            ( backtracks,
              (x, (aux iargs) gt'),
              loop (Sym.Map.add x (GT.bt gt') iargs) gt_rest )
            loc
        | Assert (lc, gt_rest) -> GT.assert_ (lc, loop iargs gt_rest) loc
        | ITE (it_if, gt_then, gt_else) ->
          GT.ite_ (it_if, aux iargs gt_then, aux iargs gt_else) loc
        | Map ((i_sym, i_bt, it_perm), gt_inner) ->
          GT.map_
            ((i_sym, i_bt, it_perm), aux (Sym.Map.add i_sym i_bt iargs) gt_inner)
            loc
      in
      gt |> propagate_constraints iargs |> loop iargs
    in
    let iargs = gd.iargs |> List.to_seq |> Sym.Map.of_seq in
    { gd with body = aux iargs gd.body }
end

module Specialization = struct
  module Equality = struct
    let find_constraint (vars : Sym.Set.t) (x : Sym.t) (gt : GT.t) : (GT.t * IT.t) option =
      let rec aux (gt : GT.t) : (GT.t * IT.t) option =
        let open Option in
        let (GT (gt_, _, loc)) = gt in
        match gt_ with
        | Arbitrary | Uniform | Alloc | Pick _ | Call _ | Return _ | ITE _ | Map _ -> None
        | Asgn ((it_addr, sct), it_val, gt_rest) ->
          let@ gt_rest, it = aux gt_rest in
          return (GT.asgn_ ((it_addr, sct), it_val, gt_rest) loc, it)
        | Let (backtracks, (x, gt_inner), gt_rest) ->
          if Config.has_pass "reorder" then
            (* We assume reordering has been applied,
               so `assert`s appear before the next `let*` *)
            None
          else
            let@ gt_rest, it = aux gt_rest in
            return (GT.let_ (backtracks, (x, gt_inner), gt_rest) loc, it)
        | Assert (T (IT (Binop (EQ, IT (Sym x', _, _), it), _, _)), gt_rest)
          when Sym.equal x x' && Sym.Set.subset (IT.free_vars it) vars ->
          return (gt_rest, it)
        | Assert (T (IT (Binop (EQ, it, IT (Sym x', _, _)), _, _)), gt_rest)
          when Sym.equal x x' && Sym.Set.subset (IT.free_vars it) vars ->
          return (gt_rest, it)
        | Assert (lc, gt_rest) ->
          let@ gt_rest, it = aux gt_rest in
          return (GT.assert_ (lc, gt_rest) loc, it)
      in
      aux gt


    let transform_gt (vars : Sym.Set.t) (gt : GT.t) : GT.t =
      let rec aux (vars : Sym.Set.t) (gt : GT.t) : GT.t =
        let (GT (gt_, _, loc)) = gt in
        match gt_ with
        | Arbitrary | Uniform | Alloc | Call _ | Return _ -> gt
        | Pick wgts -> GT.pick_ (List.map_snd (aux vars) wgts) loc
        | Asgn ((it_addr, sct), it_val, gt_rest) ->
          GT.asgn_ ((it_addr, sct), it_val, aux vars gt_rest) loc
        | Let (backtracks, (x, (GT (Uniform, _, loc) as gt_inner)), gt_rest)
        | Let (backtracks, (x, (GT (Alloc, _, loc) as gt_inner)), gt_rest) ->
          let gt_rest, gt_res =
            match find_constraint vars x gt_rest with
            | Some (gt_rest, it) -> (gt_rest, GT.return_ it loc)
            | None -> (gt_rest, gt_inner)
          in
          GT.let_ (backtracks, (x, gt_res), aux (Sym.Set.add x vars) gt_rest) loc
        | Let (backtracks, (x, gt_inner), gt_rest) ->
          GT.let_
            (backtracks, (x, aux vars gt_inner), aux (Sym.Set.add x vars) gt_rest)
            loc
        | Assert (lc, gt_rest) -> GT.assert_ (lc, aux vars gt_rest) loc
        | ITE (it_if, gt_then, gt_else) ->
          GT.ite_ (it_if, aux vars gt_then, aux vars gt_else) loc
        | Map ((i, i_bt, it_perm), gt_inner) ->
          GT.map_ ((i, i_bt, it_perm), aux (Sym.Set.add i vars) gt_inner) loc
      in
      aux vars gt


    let transform
          ({ filename : string;
             recursive : bool;
             spec;
             name : Sym.Set.elt;
             iargs : (Sym.Set.elt * BT.t) list;
             oargs : (Sym.Set.elt * BT.t) list;
             body : GT.t
           } :
            GD.t)
      : GD.t
      =
      let vars = iargs |> List.map fst |> Sym.Set.of_list in
      { filename; recursive; spec; name; iargs; oargs; body = transform_gt vars body }
  end

  module Integer = struct
    module Rep = struct
      type t =
        { mult : IT.t option;
          min : IT.t option;
          max : IT.t option
        }

      let of_mult (it : IT.t) : t = { mult = Some it; min = None; max = None }

      let of_min (it : IT.t) : t = { mult = None; min = Some it; max = None }

      let of_max (it : IT.t) : t = { mult = None; min = None; max = Some it }

      let of_it (x : Sym.t) (it : IT.t) : t option =
        let (IT (it_, _, _)) = it in
        match it_ with
        | Binop (LT, IT (Sym x', _, _), it')
          when Sym.equal x x' && not (Sym.Set.mem x (IT.free_vars it')) ->
          Some (of_max it')
        | Binop (LE, IT (Sym x', x_bt, _), it')
          when Sym.equal x x' && not (Sym.Set.mem x (IT.free_vars it')) ->
          let loc = Locations.other __LOC__ in
          Some (of_max (IT.add_ (it', IT.num_lit_ Z.one x_bt loc) loc))
        | Binop (LT, it', IT (Sym x', x_bt, _))
          when Sym.equal x x' && not (Sym.Set.mem x (IT.free_vars it')) ->
          let loc = Locations.other __LOC__ in
          Some (of_min (IT.sub_ (it', IT.num_lit_ Z.one x_bt loc) loc))
        | Binop (LE, it', IT (Sym x', _, _))
          when Sym.equal x x' && not (Sym.Set.mem x (IT.free_vars it')) ->
          Some (of_min it')
        | _ -> None


      let intersect
            ({ mult = mult1; min = min1; max = max1 } : t)
            ({ mult = mult2; min = min2; max = max2 } : t)
        : t
        =
        let mult =
          match (mult1, mult2) with
          | Some n, None | None, Some n -> Some n
          | None, None -> None
          | Some _, Some _ -> failwith __LOC__
        in
        let min =
          match (min1, min2) with
          | Some n1, Some n2 ->
            let loc = Locations.other __LOC__ in
            Some
              (Simplify.IndexTerms.simp
                 (Simplify.default Global.empty)
                 (IT.max_ (n1, n2) loc))
          | Some n, None | None, Some n -> Some n
          | None, None -> None
        in
        let max =
          match (max1, max2) with
          | Some n1, Some n2 ->
            let loc = Locations.other __LOC__ in
            Some
              (Simplify.IndexTerms.simp
                 (Simplify.default Global.empty)
                 (IT.min_ (n1, n2) loc))
          | Some n, None | None, Some n -> Some n
          | None, None -> None
        in
        { mult; min; max }
    end

    let collect_constraints (vars : Sym.Set.t) (x : Sym.t) (bt : BT.t) (stmts : GS.t list)
      : GS.t list * Rep.t
      =
      let rec aux (stmts : GS.t list) : GS.t list * Rep.t =
        match stmts with
        | (Assert (T it) as stmt) :: stmts' when Sym.Set.subset (IT.free_vars it) vars ->
          let stmts', r = aux stmts' in
          (match Rep.of_it x it with
           | Some r' -> (stmts', Rep.intersect r r')
           | None -> (stmt :: stmts', r))
        | stmt :: stmts' ->
          let stmts', v = aux stmts' in
          (stmt :: stmts', v)
        | [] ->
          (match bt with
           | Bits _ | Loc _ -> ([], { mult = None; min = None; max = None })
           | _ -> failwith __LOC__)
      in
      aux stmts


    let compile_constraints (x : Sym.t) (v : Rep.t) (gt : GT.t) : GT.t * GS.t list =
      let mult_to_stmt (mult : IT.t option) : GS.t list =
        let loc = Locations.other __LOC__ in
        match mult with
        | Some it ->
          [ Assert
              (LC.T
                 (IT.eq_
                    ( IT.mod_ (IT.sym_ (x, GT.bt gt, loc), it) loc,
                      IT.num_lit_ Z.zero (GT.bt gt) loc )
                    loc))
          ]
        | None -> []
      in
      let min_to_stmt (min : IT.t option) : GS.t list =
        let loc = Locations.other __LOC__ in
        match min with
        | Some it -> [ Assert (LC.T (IT.ge_ (IT.sym_ (x, GT.bt gt, loc), it) loc)) ]
        | None -> []
      in
      let max_to_stmt (max : IT.t option) : GS.t list =
        let loc = Locations.other __LOC__ in
        match max with
        | Some it -> [ Assert (LC.T (IT.lt_ (IT.sym_ (x, GT.bt gt, loc), it) loc)) ]
        | None -> []
      in
      match gt with
      | GT (Uniform, _, _) ->
        let loc = Locations.other __LOC__ in
        ( (match v with
           | { mult = None; min = None; max = None } -> gt
           | { mult = Some n; min = None; max = None } ->
             GenBuiltins.mult_gen n (GT.bt gt) loc
           | { mult = None; min = Some n; max = None } ->
             GenBuiltins.ge_gen n (GT.bt gt) loc
           | { mult = None; min = None; max = Some n } ->
             GenBuiltins.lt_gen n (GT.bt gt) loc
           | { mult = None; min = Some n1; max = Some n2 } ->
             GenBuiltins.range_gen n1 n2 (GT.bt gt) loc
           | { mult = Some n1; min = Some n2; max = None } ->
             GenBuiltins.mult_ge_gen n1 n2 (GT.bt gt) loc
           | { mult = Some n1; min = None; max = Some n2 } ->
             GenBuiltins.mult_lt_gen n1 n2 (GT.bt gt) loc
           | { mult = Some n1; min = Some n2; max = Some n3 } ->
             GenBuiltins.mult_range_gen n1 n2 n3 (GT.bt gt) loc),
          [] )
      | GT (Alloc, _, _) when Option.is_some v.mult ->
        let loc = Locations.other __LOC__ in
        (match v with
         | { mult = Some n; min; max } ->
           ( GenBuiltins.aligned_alloc_gen n (IT.num_lit_ Z.zero (IT.get_bt n) loc) loc,
             min_to_stmt min @ max_to_stmt max )
         | _ -> failwith ("unreachable @ " ^ __LOC__))
      | _ -> (gt, mult_to_stmt v.mult @ min_to_stmt v.min @ max_to_stmt v.max)


    let specialize_stmts (vars : Sym.Set.t) (stmts : GS.t list) : GS.t list =
      let rec aux (vars : Sym.Set.t) (stmts : GS.t list) : GS.t list =
        match stmts with
        | Let (backtracks, (x, gt)) :: stmts' ->
          let vars = Sym.Set.add x vars in
          let stmts', (gt, stmts'') =
            if
              BT.equal (GT.bt gt) (BT.Loc ()) || Option.is_some (BT.is_bits_bt (GT.bt gt))
            then (
              let stmts', v = collect_constraints vars x (GT.bt gt) stmts' in
              (stmts', compile_constraints x v gt))
            else
              (stmts', (gt, []))
          in
          (GS.Let (backtracks, (x, gt)) :: stmts'') @ aux vars stmts'
        | stmt :: stmts' -> stmt :: aux vars stmts'
        | [] -> []
      in
      aux vars stmts


    let specialize (vars : Sym.Set.t) (gt : GT.t) : GT.t =
      let stmts, gt_last = GS.stmts_of_gt gt in
      let stmts = specialize_stmts vars stmts in
      GS.gt_of_stmts stmts gt_last


    let transform (gd : GD.t) : GD.t =
      let rec aux (vars : Sym.Set.t) (gt : GT.t) : GT.t =
        let rec loop (vars : Sym.Set.t) (gt : GT.t) : GT.t =
          let (GT (gt_, _bt, loc)) = gt in
          match gt_ with
          | Arbitrary | Uniform | Alloc | Call _ | Return _ -> gt
          | Pick wgts -> GT.pick_ (List.map_snd (aux vars) wgts) loc
          | Asgn ((it_addr, sct), it_val, gt_rest) ->
            GT.asgn_ ((it_addr, sct), it_val, loop vars gt_rest) loc
          | Let (backtracks, (x, gt'), gt_rest) ->
            GT.let_
              (backtracks, (x, (aux vars) gt'), loop (Sym.Set.add x vars) gt_rest)
              loc
          | Assert (lc, gt_rest) -> GT.assert_ (lc, loop vars gt_rest) loc
          | ITE (it_if, gt_then, gt_else) ->
            GT.ite_ (it_if, aux vars gt_then, aux vars gt_else) loc
          | Map ((i_sym, i_bt, it_perm), gt_inner) ->
            GT.map_ ((i_sym, i_bt, it_perm), aux (Sym.Set.add i_sym vars) gt_inner) loc
        in
        gt |> specialize vars |> loop vars
      in
      let iargs = gd.iargs |> List.map fst |> Sym.Set.of_list in
      { gd with body = aux iargs gd.body }
  end
end

let debug msg = Cerb_debug.print_debug 2 [] (fun _ -> msg)

let all_passes (prog5 : unit Mucore.file) =
  [ PartialEvaluation.pass prog5 ]
  @ (if Config.has_pass "flatten" then [ PushPull.pass ] else [])
  @ Inline.passes
  @ RemoveUnused.passes
  @ [ TermSimplification.pass prog5; TermSimplification'.pass ]
  @ BranchPruning.passes
  @ if Config.has_pass "lift_constraints" then SplitConstraints.passes else []


let optimize_gen (prog5 : unit Mucore.file) (passes : StringSet.t) (gt : GT.t) : GT.t =
  let passes =
    all_passes prog5
    |> List.filter_map (fun { name; transform } ->
      if StringSet.mem name passes then
        Some
          (fun gt ->
            debug name;
            transform gt)
      else
        None)
  in
  let opt (gt : GT.t) : GT.t =
    gt
    |> List.fold_right (fun pass gt -> pass gt) passes
    |> GenNormalize.MemberIndirection.transform
  in
  let rec loop (fuel : int) (gt : GT.t) : GT.t =
    if fuel <= 0 then
      gt
    else (
      let old_gt = gt in
      let new_gt = opt gt in
      if GT.equal old_gt new_gt then new_gt else loop (fuel - 1) new_gt)
  in
  gt |> loop 5


let optimize_gen_def (prog5 : unit Mucore.file) (passes : StringSet.t) (gd : GD.t) : GD.t =
  let aux ({ filename; recursive; spec; name; iargs; oargs; body } : GD.t) : GD.t =
    { filename;
      recursive;
      name;
      spec;
      iargs;
      oargs;
      body = optimize_gen prog5 passes body
    }
  in
  gd
  |> aux
  |> (debug "fusion_each";
      Fusion.Each.transform)
  |> aux
  |> (if Config.has_pass "picks" then (
        debug "flip_ifs";
        FlipIfs.transform)
      else
        fun gd' -> gd')
  |> aux
  |> (if Config.has_pass "reorder" then (
        debug "reorder";
        Reordering.transform [])
      else
        fun gd' -> gd')
  |> (if Config.has_pass "consistency" then
        fun gd' ->
      gd'
      |> (debug "constraint_propagation";
          ConstraintPropagation.transform)
      |> (debug "specialization_equality";
          Specialization.Equality.transform)
      |>
      (debug "specialization_integer";
       Specialization.Integer.transform)
      else
        fun gd' -> gd')
  |> aux


let optimize (prog5 : unit Mucore.file) ?(passes : StringSet.t option = None) (ctx : GC.t)
  : GC.t
  =
  let default = all_passes prog5 |> List.map (fun p -> p.name) |> StringSet.of_list in
  let passes = Option.value ~default passes in
  List.map_snd (optimize_gen_def prog5 passes) ctx
