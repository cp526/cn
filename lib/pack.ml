open Request
open Resource
open Definition
open Memory
module IT = IndexTerms
module LAT = LogicalArgumentTypes
module LRT = LogicalReturnTypes
module LC = LogicalConstraints

(* open Cerb_pp_prelude *)

let resource_empty provable resource =
  let loc = Cerb_location.other __LOC__ in
  let constr =
    match resource with
    | P _, _ -> LC.T (IT.bool_ false loc)
    | Q p, _ -> LC.forall_ p.q (IT.not_ p.permission loc)
  in
  match provable constr with
  | `True -> `Empty
  | `False -> `NonEmpty (constr, Solver.model ())


let unfolded_array loc init (ict, olength) pointer =
  let length = Option.get olength in
  let q_s, q = IT.fresh_named Memory.uintptr_bt "i" loc in
  Q
    { name = Owned (ict, init);
      pointer;
      q = (q_s, Memory.uintptr_bt);
      q_loc = loc;
      step = ict;
      iargs = [];
      permission =
        IT.(
          and_
            [ le_ (uintptr_int_ 0 loc, q) loc; lt_ (q, uintptr_int_ length loc) loc ]
            loc)
    }


let packing_ft ~full loc global provable ret =
  match ret with
  | P ret ->
    (match ret.name with
     | Owned ((Void | Integer _ | Pointer _ | Function _ | Byte), _init) -> None
     | Owned ((Array (ict, olength) as ct), init) ->
       let qpred = unfolded_array loc init (ict, olength) ret.pointer in
       let o_s, o = IT.fresh_named (Memory.bt_of_sct ct) "value" loc in
       let at = LAT.Resource ((o_s, (qpred, IT.get_bt o)), (loc, None), LAT.I o) in
       Some at
     | Owned (Struct tag, init) ->
       let layout = Sym.Map.find tag global.Global.struct_decls in
       let lrt, value =
         List.fold_right
           (fun { offset; size; member_or_padding } (lrt, value) ->
              match member_or_padding with
              | Some (member, mct) ->
                let request =
                  P
                    { name = Owned (mct, init);
                      pointer = IT.memberShift_ (ret.pointer, tag, member) loc;
                      iargs = []
                    }
                in
                let m_value_s, m_value =
                  IT.fresh_named (Memory.bt_of_sct mct) (Id.get_string member) loc
                in
                ( LRT.Resource
                    ((m_value_s, (request, IT.get_bt m_value)), (loc, None), lrt),
                  (member, m_value) :: value )
              | None ->
                let padding_ct = Sctypes.Array (Sctypes.char_ct, Some size) in
                let request =
                  P
                    { name = Owned (padding_ct, Uninit);
                      pointer =
                        IT.pointer_offset_ (ret.pointer, IT.uintptr_int_ offset loc) loc;
                      iargs = []
                    }
                in
                let padding_s, padding =
                  IT.fresh_named (Memory.bt_of_sct padding_ct) "padding" loc
                in
                ( LRT.Resource
                    ((padding_s, (request, IT.get_bt padding)), (loc, None), lrt),
                  value ))
           layout
           (LRT.I, [])
       in
       let at = LAT.of_lrt lrt (LAT.I (IT.struct_ (tag, value) loc)) in
       Some at
     | PName pn ->
       let def = Sym.Map.find pn global.resource_predicates in
       if (not full) && (Predicate.is_multiclause def || Predicate.is_nounfold def) then
         None
       else (
         match Predicate.identify_right_clause provable def ret.pointer ret.iargs with
         | None -> None
         | Some right_clause -> Some right_clause.packing_ft))
  | Q _ -> None


let unpack_owned loc global (ct, init) pointer (O o) =
  let open Sctypes in
  match ct with
  | Void | Integer _ | Pointer _ | Function _ | Byte -> None
  | Array (ict, olength) -> Some [ (unfolded_array loc init (ict, olength) pointer, O o) ]
  | Struct tag ->
    let layout = Sym.Map.find tag global.Global.struct_decls in
    let res =
      List.fold_right
        (fun { offset; size; member_or_padding } res ->
           match member_or_padding with
           | Some (member, mct) ->
             let mresource =
               ( P
                   { name = Owned (mct, init);
                     pointer = IT.memberShift_ (pointer, tag, member) loc;
                     iargs = []
                   },
                 O (IT.member_ ~member_bt:(Memory.bt_of_sct mct) (o, member) loc) )
             in
             mresource :: res
           | None ->
             let padding_ct = Sctypes.Array (Sctypes.char_ct, Some size) in
             let mresource =
               ( P
                   { name = Owned (padding_ct, Uninit);
                     pointer =
                       IT.pointer_offset_ (pointer, IT.uintptr_int_ offset loc) loc;
                     iargs = []
                   },
                 O (IT.default_ (Memory.bt_of_sct padding_ct) loc) )
             in
             mresource :: res)
        layout
        []
    in
    Some res


let unpack ~full loc global provable (ret, O o) =
  match ret with
  | P { name = Owned (ct, init); pointer; iargs = [] } ->
    (match unpack_owned loc global (ct, init) pointer (O o) with
     | None -> None
     | Some re -> Some (`RES re))
  | _ ->
    (match packing_ft ~full loc global provable ret with
     | None -> None
     | Some packing_ft -> Some (`LRT (Definition.Clause.lrt o packing_ft)))


let extractable_one (* global *) provable (predicate_name, index) (ret, O o) =
  (* let tmsg hd tail =  *)
  (*   if verb *)
  (*   then Pp.print stdout (Pp.item hd (Request.pp ret ^^ Pp.hardline ^^ *)
  (*         Pp.string "--" ^^ Pp.hardline ^^ Lazy.force tail)) *)
  (*   else () *)
  (* in *)
  match ret with
  | Q ret
    when Request.equal_name predicate_name ret.name
         && BT.equal (IT.get_bt index) (snd ret.q) ->
    let su = IT.make_subst [ (fst ret.q, index) ] in
    let index_permission = IT.subst su ret.permission in
    (match provable (LC.T index_permission) with
     | `True ->
       let loc = Cerb_location.other __LOC__ in
       let at_index =
         ( P
             { name = ret.name;
               pointer = IT.(arrayShift_ ~base:ret.pointer ~index ret.step loc);
               iargs = List.map (IT.subst su) ret.iargs
             },
           O (IT.map_get_ o index loc) )
       in
       let ret_reduced =
         { ret with
           permission =
             IT.(
               and_
                 [ ret.permission; ne__ (sym_ (fst ret.q, snd ret.q, loc)) index loc ]
                 loc)
         }
       in
       (* tmsg "successfully extracted" (lazy (IT.pp index)); *)
       Some ((Q ret_reduced, O o), at_index)
     | `False -> None)
  | _ -> None


let extractable_multiple (* global *) prove_or_model =
  let rec aux is (re, extracted) =
    match is with
    | [] -> (re, extracted)
    | i :: is ->
      (match extractable_one (* global *) prove_or_model i re with
       | Some (re_reduced, extracted') -> aux is (re_reduced, extracted' :: extracted)
       | None -> aux is (re, extracted))
  in
  fun movable_indices re -> aux movable_indices (re, [])
