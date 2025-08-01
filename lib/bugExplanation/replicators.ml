module CF = Cerb_frontend
module A = CF.AilSyntax
module C = CF.Ctype
module BT = BaseTypes
module IT = IndexTerms
module AT = ArgumentTypes
module LAT = LogicalArgumentTypes
module CtA = Fulminate.Cn_to_ail
module Utils = Fulminate.Utils

let mk_expr = Utils.mk_expr

let mk_stmt = Utils.mk_stmt

let rec string_of_ctype ctype =
  match ctype with
  | C.Ctype (_, Pointer (_, Ctype (_, Function ((_, ret), args, _)))) ->
    string_of_ctype ret
    ^ "_from_"
    ^ String.concat "_and_" (List.map (fun (_, ct, _) -> string_of_ctype ct) args)
  | _ -> String.concat "_" (String.split_on_char ' ' (Utils.str_of_ctype ctype))


let bt_to_ctype (bt : BT.t) : C.ctype = CtA.bt_to_ail_ctype bt

let name_of_bt (bt : BT.t) : string =
  let ct = bt_to_ctype bt in
  let ct' =
    match bt_to_ctype bt with Ctype (_, Pointer (_, ct')) -> ct' | _ -> failwith __LOC__
  in
  let default =
    CF.Pp_utils.to_plain_string
      CF.Pp_ail.(with_executable_spec (pp_ctype C.no_qualifiers) ct')
  in
  Utils.get_typedef_string ct |> Option.value ~default


let owned_sct_sym (ct : C.ctype) : Sym.t =
  Sym.fresh ("cn_replicate_owned_" ^ string_of_ctype ct)


let owned_sct_aux_sym (ct : C.ctype) : Sym.t =
  Sym.fresh ("cn_replicate_owned_" ^ string_of_ctype ct ^ "_aux")


let pred_sym (psym : Sym.t) : Sym.t = Sym.fresh ("cn_replicate_" ^ Sym.pp_string psym)

let append_line_sym = Sym.fresh "cn_replica_lines_append"

let _append_line_call line =
  A.AilSexpr (mk_expr (AilEcall (mk_expr (AilEident append_line_sym), [ line ])))


let rec buf_length (fmt : string list) (args : string list) : string list =
  match (fmt, args) with
  | "%s" :: fmt', arg :: args' -> ("strlen(" ^ arg ^ ")") :: buf_length fmt' args'
  | s :: fmt', _ :: args' when String.starts_with ~prefix:"%" s ->
    string_of_int
      (String.length
         (Z.to_string
            (Memory.max_integer_type
               (Sctypes.IntegerTypes.Unsigned Sctypes.IntegerBaseTypes.Intmax_t))))
    :: buf_length fmt' args'
  | s :: _, [] when String.starts_with ~prefix:"%" s ->
    failwith "Too few arguments for format string"
  | s :: fmt', args -> string_of_int (String.length s) :: buf_length fmt' args
  | [], _ :: _ -> failwith "Extra arguments remaining for format string"
  | [], [] -> []


let sprintf_to_buf (buf_sym : Sym.t) (fmt : string list) (args : string list) =
  let b_buf = Utils.create_binding buf_sym C.pointer_to_char in
  let e_args = List.map (fun x -> mk_expr (AilEident (Sym.fresh x))) args in
  let buf_len_sym = Sym.fresh_anon () in
  let b_buf_len = Utils.create_binding buf_len_sym C.size_t in
  let s =
    A.(
      [ AilSdeclaration
          [ ( buf_len_sym,
              Some
                (mk_expr
                   (AilEident
                      (Sym.fresh (String.concat " + " (buf_length fmt args) ^ " + 1"))))
            )
          ];
        AilSdeclaration
          [ ( buf_sym,
              Some
                (mk_expr
                   (AilEcall
                      ( mk_expr (AilEident (Sym.fresh "malloc")),
                        [ mk_expr (AilEident buf_len_sym) ] ))) )
          ];
        AilSexpr
          (mk_expr
             (AilEcall
                ( mk_expr (AilEident (Sym.fresh "snprintf")),
                  [ mk_expr (AilEident buf_sym);
                    mk_expr (AilEident buf_len_sym);
                    mk_expr (AilEstr (None, [ (Locations.other __LOC__, fmt) ]))
                  ]
                  @ e_args )))
      ]
      @ List.map
          (fun e_arg ->
             AilSexpr
               (mk_expr (AilEcall (mk_expr (AilEident (Sym.fresh "free")), [ e_arg ]))))
          e_args)
  in
  ([ b_buf; b_buf_len ], s)


let replicate_call (sct : Sctypes.t) e_arg =
  match sct with
  | Sctypes.Array (sct', Some n) ->
    let fsym = Sym.fresh "cn_replicate_owned_array_aux" in
    A.AilEcall
      ( mk_expr (AilEident fsym),
        [ mk_expr (AilEident (owned_sct_aux_sym (Sctypes.to_ctype sct')));
          mk_expr e_arg;
          mk_expr (AilEconst (ConstantInteger (IConstant (Z.of_int n, Decimal, None))))
        ] )
  | Integer _ ->
    let bt = Memory.bt_of_sct sct in
    A.AilEcall
      ( mk_expr (AilEident (Sym.fresh ("cn_replicate_owned_" ^ name_of_bt bt ^ "_aux"))),
        [ mk_expr e_arg ] )
  | Array (_, None) | Pointer _ ->
    A.AilEcall
      ( mk_expr (AilEident (Sym.fresh "cn_replicate_owned_cn_pointer_aux")),
        [ mk_expr e_arg ] )
  | Struct _ ->
    let fsym = owned_sct_aux_sym (Sctypes.to_ctype sct) in
    let e_arg =
      CtA.wrap_with_convert_to (AilEunary (Address, mk_expr e_arg)) (BT.Loc ())
    in
    A.AilEcall (mk_expr (AilEident fsym), [ mk_expr e_arg ])
  | _ ->
    let bt = Memory.bt_of_sct sct in
    let fsym = owned_sct_aux_sym (Sctypes.to_ctype sct) in
    let e_arg = CtA.wrap_with_convert_to ~sct e_arg bt in
    A.AilEcall (mk_expr (AilEident fsym), [ mk_expr e_arg ])


let replicate_member ptr_sym (sct : Sctypes.t) ((member, sct') : Id.t * Sctypes.t) =
  let e_arg =
    A.AilEmemberofptr
      ( mk_expr
          (AilEcast
             ( C.no_qualifiers,
               Sctypes.to_ctype (Sctypes.pointer_ct sct),
               mk_expr (CtA.wrap_with_convert_from (AilEident ptr_sym) (BT.Loc ())) )),
        member )
  in
  let e_arg =
    match sct' with
    | Pointer _ -> CtA.wrap_with_convert_to e_arg (BT.Loc ())
    | Integer _ ->
      CtA.wrap_with_convert_to (AilEunary (Address, mk_expr e_arg)) (BT.Loc ())
    | _ -> e_arg
  in
  replicate_call sct' e_arg


let compile_sct_aux (prog5 : unit Mucore.file) (sct : Sctypes.t)
  : A.sigma_declaration * CF.GenTypes.genTypeCategory A.sigma_function_definition
  =
  let fsym = owned_sct_aux_sym (Sctypes.to_ctype sct) in
  let ptr_sym = Sym.fresh "ptr" in
  let buf_sym = Sym.fresh "buf" in
  let b1, s1 =
    match sct with
    | Void -> failwith __LOC__
    | Byte -> failwith ("TODO: Byte case for " ^ __FUNCTION__)
    | Integer _ ->
      ( [ Utils.create_binding buf_sym C.pointer_to_char ],
        A.
          [ AilSdeclaration
              [ (buf_sym, Some (mk_expr (replicate_call sct (AilEident ptr_sym)))) ]
          ] )
    | Array (sct', Some n) ->
      let range m =
        let rec aux i acc =
          if i < 0 then
            acc
          else
            aux (i - 1) (i :: acc)
        in
        aux (m - 1) []
      in
      let mem_syms =
        List.map (fun i -> Sym.fresh ("index_" ^ string_of_int i)) (range n)
      in
      let b_mem, s_mem =
        let b, s =
          mem_syms
          |> List.combine (range n)
          |> List.map (fun (i, mem_sym) ->
            ( [ Utils.create_binding mem_sym C.pointer_to_char ],
              A.
                [ AilSdeclaration
                    [ ( mem_sym,
                        Some
                          (mk_expr
                             (replicate_call
                                sct'
                                (CtA.wrap_with_convert_to
                                   (AilEcast
                                      ( C.no_qualifiers,
                                        Sctypes.to_ctype (Pointer sct'),
                                        mk_expr
                                          (AilEbinary
                                             ( mk_expr
                                                 (CtA.wrap_with_convert_to
                                                    (AilEident ptr_sym)
                                                    (BT.Loc ())),
                                               Arithmetic Add,
                                               mk_expr
                                                 (AilEconst
                                                    (ConstantInteger
                                                       (IConstant
                                                          (Z.of_int i, Decimal, None))))
                                             )) ))
                                   (BT.Loc ())))) )
                    ]
                ] ))
          |> List.split
        in
        (List.flatten b, List.flatten s)
      in
      let b_buf, s_buf =
        (sprintf_to_buf
           buf_sym
           ([ "{ " ]
            @ List.concat_map
                (fun i -> if i = 0 then [ "%s" ] else [ ", "; "%s" ])
                (range n)
            @ [ " }" ]))
          (List.map Sym.pp_string mem_syms)
      in
      (b_mem @ b_buf, s_mem @ s_buf)
    | Array (_, None) ->
      ( [ Utils.create_binding buf_sym C.pointer_to_char ],
        A.
          [ AilSdeclaration
              [ ( buf_sym,
                  Some
                    (mk_expr
                       (AilEcall
                          ( mk_expr
                              (AilEident (Sym.fresh "cn_replicate_owned_cn_pointer_aux")),
                            [ mk_expr
                                (AilEcast
                                   ( C.no_qualifiers,
                                     bt_to_ctype (BT.Loc ()),
                                     mk_expr
                                       (CtA.wrap_with_convert_from
                                          (AilEident ptr_sym)
                                          (BT.Loc ())) ))
                            ] ))) )
              ]
          ] )
    | Pointer _ ->
      ( [ Utils.create_binding buf_sym C.pointer_to_char ],
        A.
          [ AilSdeclaration
              [ ( buf_sym,
                  Some
                    (mk_expr
                       (AilEcall
                          ( mk_expr
                              (AilEident (Sym.fresh "cn_replicate_owned_cn_pointer_aux")),
                            [ mk_expr (AilEident ptr_sym) ] ))) )
              ]
          ] )
    | Struct tag ->
      (match Pmap.find tag prog5.tagDefs with
       | StructDef pieces ->
         let members =
           pieces
           |> List.filter_map (fun ({ member_or_padding; _ } : Memory.struct_piece) ->
             member_or_padding)
         in
         let b, s =
           A.(
             members
             |> List.map (fun (member, sct') ->
               let member_sym = Sym.fresh (Id.get_string member ^ "_mem_str") in
               ( Utils.create_binding member_sym C.pointer_to_char,
                 AilSdeclaration
                   [ ( member_sym,
                       Some (mk_expr (replicate_member ptr_sym sct (member, sct'))) )
                   ] )))
           |> List.split
         in
         let b2, s2 =
           sprintf_to_buf
             buf_sym
             ([ "(struct " ^ Sym.pp_string tag ^ ") { " ]
              @ (members
                 |> List.map (fun (member, _sct) ->
                   [ "." ^ Id.get_string member ^ " = "; "%s" ])
                 |> List.fold_left
                      (fun acc l -> match acc with [] -> l | _ -> acc @ [ ", " ] @ l)
                      [])
              @ [ " }" ])
             (members
              |> List.map (fun (member, _) -> [ Id.get_string member ^ "_mem_str" ])
              |> List.flatten)
         in
         (b @ b2, s @ s2)
       | _ -> failwith __LOC__)
    | Function _ -> failwith "Functions are impossible"
  in
  let s =
    mk_stmt
      A.(
        AilSblock
          (b1, s1 @ [ AilSreturn (mk_expr (AilEident buf_sym)) ] |> List.map mk_stmt))
  in
  let cn_pointer_sct = (C.no_qualifiers, bt_to_ctype (BT.Loc ()), false) in
  let decl =
    ( fsym,
      ( Locations.other __LOC__,
        CF.Annot.Attrs [],
        A.Decl_function
          ( false,
            (C.no_qualifiers, C.pointer_to_char),
            [ cn_pointer_sct ],
            false,
            false,
            false ) ) )
  in
  let def = (fsym, (Locations.other __LOC__, 0, CF.Annot.Attrs [], [ ptr_sym ], s)) in
  (decl, def)


let compile_sct (sct : Sctypes.t)
  : A.sigma_declaration * CF.GenTypes.genTypeCategory A.sigma_function_definition
  =
  let fsym = owned_sct_sym (Sctypes.to_ctype sct) in
  let ptr_sym = Sym.fresh "ptr" in
  let addr_str_sym = Sym.fresh "addr_str" in
  let cast_addr_str_sym = Sym.fresh "cast_addr_str" in
  let value_str_sym = Sym.fresh "value_str" in
  let bt = Memory.bt_of_sct sct in
  let b_cast, s_cast =
    sprintf_to_buf
      cast_addr_str_sym
      [ "*((" ^ Pp.plain (Sctypes.pp (Sctypes.pointer_ct sct)) ^ ")"; "%s"; ")" ]
      [ Sym.pp_string addr_str_sym ]
  in
  let s =
    mk_stmt
      A.(
        AilSblock
          ( [ Utils.create_binding addr_str_sym C.pointer_to_char;
              Utils.create_binding value_str_sym C.pointer_to_char
            ]
            @ b_cast,
            [ mk_stmt
                (AilSdeclaration
                   [ ( addr_str_sym,
                       Some
                         (mk_expr
                            (AilEcall
                               ( mk_expr
                                   (AilEident
                                      (Sym.fresh "cn_replicate_owned_cn_pointer_aux")),
                                 [ mk_expr (AilEident ptr_sym) ] ))) )
                   ]);
              mk_stmt
                (AilSdeclaration
                   [ ( value_str_sym,
                       Some
                         (mk_expr
                            (AilEcall
                               ( mk_expr
                                   (AilEident (owned_sct_aux_sym (Sctypes.to_ctype sct))),
                                 [ mk_expr (AilEident ptr_sym) ] ))) )
                   ])
            ]
            @ List.map mk_stmt s_cast
            @ [ mk_stmt
                  (AilSexpr
                     (mk_expr
                        (AilEcall
                           ( mk_expr (AilEident (Sym.fresh "cn_replicate_owned")),
                             [ mk_expr (AilEident cast_addr_str_sym);
                               mk_expr (AilEident value_str_sym)
                             ] ))));
                mk_stmt
                  (AilSreturn
                     (mk_expr
                        (CtA.wrap_with_convert_to
                           ~sct
                           (AilEunary
                              ( Indirection,
                                mk_expr
                                  (AilEcast
                                     ( C.no_qualifiers,
                                       Sctypes.to_ctype
                                         (Sctypes.pointer_ct
                                            (match sct with
                                             | Array (sct', _) -> Pointer sct'
                                             | _ -> sct)),
                                       mk_expr
                                         (CtA.wrap_with_convert_from
                                            (AilEident ptr_sym)
                                            (BT.Loc ())) )) ))
                           bt)))
              ] ))
  in
  let cn_pointer_sct = (C.no_qualifiers, bt_to_ctype (BT.Loc ()), false) in
  let decl =
    ( fsym,
      ( Locations.other __LOC__,
        CF.Annot.Attrs [],
        A.Decl_function
          ( false,
            (C.no_qualifiers, bt_to_ctype bt),
            [ cn_pointer_sct ],
            false,
            false,
            false ) ) )
  in
  let def = (fsym, (Locations.other __LOC__, 0, CF.Annot.Attrs [], [ ptr_sym ], s)) in
  (decl, def)


let rec extract_global_variables = function
  | [] -> []
  | (sym, globs) :: ds ->
    (match globs with
     | Mucore.GlobalDef (ctype, _) ->
       (sym, Sctypes.to_ctype ctype) :: extract_global_variables ds
     | GlobalDecl ctype -> (sym, Sctypes.to_ctype ctype) :: extract_global_variables ds)


let compile_it
      filename
      (sigma : CF.GenTypes.genTypeCategory A.sigma)
      (prog5 : unit Mucore.file)
      (it : IT.t)
  =
  CtA.cn_to_ail_expr_toplevel
    filename
    sigma.cn_datatypes
    (extract_global_variables prog5.globs)
    None
    None
    it


let owned_sct_call
      filename
      (sigma : CF.GenTypes.genTypeCategory A.sigma)
      (prog5 : unit Mucore.file)
      (sct : Sctypes.t)
      (pointer : IT.t)
  : A.bindings
    * CF.GenTypes.genTypeCategory A.statement_ list
    * CF.GenTypes.genTypeCategory A.expression
  =
  let b1, s1, e1 = compile_it filename sigma prog5 pointer in
  let fsym = owned_sct_sym (Sctypes.to_ctype sct) in
  let e2 = mk_expr A.(AilEcall (mk_expr (AilEident fsym), [ e1 ])) in
  (b1, s1, e2)


let compile_req
      filename
      (sigma : CF.GenTypes.genTypeCategory A.sigma)
      (prog5 : unit Mucore.file)
      (req : Request.t)
      (loc : Locations.t)
  : A.bindings
    * CF.GenTypes.genTypeCategory A.statement_ list
    * CF.GenTypes.genTypeCategory A.expression
  =
  let rec aux (req : Request.t) =
    match req with
    | P { name = Owned (sct, _); pointer; iargs } ->
      assert (List.is_empty iargs);
      owned_sct_call filename sigma prog5 sct pointer
    | P { name = PName name; pointer; iargs } ->
      let b, s, es =
        pointer :: iargs
        |> List.map (compile_it filename sigma prog5)
        |> List.fold_left
             (fun (b, s, es) (b', s', e) -> (b @ b', s @ s', es @ [ e ]))
             ([], [], [])
      in
      let e = A.(mk_expr (AilEcall (mk_expr (AilEident (pred_sym name)), es))) in
      (b, s, e)
    | Q { name; pointer; q = q_sym, q_bt; q_loc; step; permission; iargs } ->
      assert (List.is_empty iargs);
      let q_it = IT.sym_ (q_sym, q_bt, q_loc) in
      let e_perm =
        let b_perm, s_perm, e_perm = compile_it filename sigma prog5 permission in
        A.(
          mk_expr
            (AilEgcc_statement (b_perm, List.map mk_stmt (s_perm @ [ AilSexpr e_perm ]))))
      in
      let b1, s1, e_min, e_max =
        let it_min, it_max = IT.Bounds.get_bounds (q_sym, q_bt) permission in
        let b1, s1, e_min = compile_it filename sigma prog5 it_min in
        let b2, s2, e_max = compile_it filename sigma prog5 it_max in
        (b1 @ b2, s1 @ s2, e_min, e_max)
      in
      let map_sym = Sym.fresh_anon () in
      let b_val, s_val, e_val =
        aux
          (P { name; pointer = IT.arrayShift_ ~base:pointer ~index:q_it step loc; iargs })
      in
      let s2 =
        A.
          [ AilSexpr
              (mk_expr
                 (AilEcall
                    ( mk_expr (AilEident (Sym.fresh "CN_REPLICATE_EACH_BEGIN")),
                      List.map
                        mk_expr
                        [ AilEident map_sym;
                          AilEident q_sym;
                          AilEident (Sym.fresh (name_of_bt q_bt))
                        ]
                      @ [ e_perm; e_min ] )))
          ]
        @ s_val
        @ [ AilSexpr
              (mk_expr
                 (AilEcall
                    ( mk_expr (AilEident (Sym.fresh "CN_REPLICATE_EACH_END")),
                      List.map
                        mk_expr
                        [ AilEident map_sym;
                          AilEident q_sym;
                          AilEident (Sym.fresh (name_of_bt q_bt))
                        ]
                      @ [ e_val; e_max ] )))
          ]
      in
      (b1 @ b_val, s1 @ s2, mk_expr (A.AilEident map_sym))
  in
  aux req


let compile_lat
      ?(f : 'a -> A.bindings * CF.GenTypes.genTypeCategory A.statement_ list =
        fun _ -> ([], []))
      filename
      (sigma : CF.GenTypes.genTypeCategory A.sigma)
      (prog5 : unit Mucore.file)
      (lat : 'a LAT.t)
  : A.bindings * CF.GenTypes.genTypeCategory A.statement_ list
  =
  let rec aux (lat : 'a LAT.t) =
    match lat with
    | Define ((x, it), _, lat') ->
      let b1, s1, e = compile_it filename sigma prog5 it in
      let b2 = [ Utils.create_binding x (bt_to_ctype (IT.get_bt it)) ] in
      let s2 = A.[ AilSdeclaration [ (x, Some e) ] ] in
      let b3, s3 = aux lat' in
      (b1 @ b2 @ b3, s1 @ s2 @ s3)
    | Resource ((x, (req, bt)), (loc, _), lat') ->
      let b1, s1, e = compile_req filename sigma prog5 req loc in
      let b2 = [ Utils.create_binding x (bt_to_ctype bt) ] in
      let s2 =
        if BT.equal bt BT.Unit then
          A.[ AilSexpr e ]
        else
          A.[ AilSdeclaration [ (x, Some e) ] ]
      in
      let b3, s3 = aux lat' in
      (b1 @ b2 @ b3, s1 @ s2 @ s3)
    | Constraint (_, _, lat') -> aux lat'
    | I i -> f i
  in
  aux lat


let compile_clauses
      filename
      (sigma : CF.GenTypes.genTypeCategory A.sigma)
      (prog5 : unit Mucore.file)
      (cls : Definition.Clause.t list)
  : A.bindings * CF.GenTypes.genTypeCategory A.statement_ list
  =
  let rec aux (cls : Definition.Clause.t list)
    : A.bindings * CF.GenTypes.genTypeCategory A.statement_ list
    =
    let aux_it it =
      if BT.equal (IT.get_bt it) BT.Unit then
        ([], [ A.AilSreturnVoid ])
      else (
        let b, s, e = compile_it filename sigma prog5 it in
        (b, s @ [ AilSreturn e ]))
    in
    match cls with
    | [ cl ] ->
      assert (IT.is_true cl.guard);
      compile_lat ~f:aux_it filename sigma prog5 cl.packing_ft
    | cl :: cls' ->
      let b_if, s_if, e_if = compile_it filename sigma prog5 cl.guard in
      let b_then, s_then = compile_lat ~f:aux_it filename sigma prog5 cl.packing_ft in
      let b_else, s_else = aux cls' in
      let s_then_else =
        A.
          [ AilSif
              ( CtA.wrap_with_convert_from_cn_bool e_if,
                mk_stmt (AilSblock (b_then, List.map mk_stmt s_then)),
                mk_stmt (AilSblock (b_else, List.map mk_stmt s_else)) )
          ]
      in
      (b_if, s_if @ s_then_else)
    | [] -> failwith ("unreachable @ " ^ __LOC__)
  in
  aux cls


let compile_pred
      filename
      (sigma : CF.GenTypes.genTypeCategory A.sigma)
      (prog5 : unit Mucore.file)
      (sym : Sym.t)
      (pred : Definition.Predicate.t)
  : A.sigma_declaration * CF.GenTypes.genTypeCategory A.sigma_function_definition
  =
  let fsym = pred_sym sym in
  let ret_type = CtA.bt_to_ail_ctype ~pred_sym:(Some sym) (snd pred.oarg) in
  let bs, ss =
    match pred.clauses with
    | Some clauses -> compile_clauses filename sigma prog5 clauses
    | None -> ([], [])
  in
  let params =
    List.map
      (fun (sym, bt) -> (sym, bt_to_ctype bt))
      ((pred.pointer, BT.(Loc ())) :: pred.iargs)
  in
  let param_syms, param_types = List.split params in
  let param_types = List.map (fun t -> (C.no_qualifiers, t, false)) param_types in
  let decl =
    ( fsym,
      ( pred.loc,
        CF.Annot.Attrs [],
        A.(
          Decl_function
            (false, (C.no_qualifiers, ret_type), param_types, false, false, false)) ) )
  in
  let def =
    ( fsym,
      ( pred.loc,
        0,
        CF.Annot.Attrs [],
        param_syms,
        mk_stmt A.(AilSblock (bs, List.map mk_stmt ss)) ) )
  in
  (decl, def)


let compile_spec
      filename
      (sigma : CF.GenTypes.genTypeCategory A.sigma)
      (prog5 : unit Mucore.file)
      (is_static : bool)
      (sym : Sym.t)
      (at : 'a AT.t)
  : A.sigma_declaration * CF.GenTypes.genTypeCategory A.sigma_function_definition
  =
  let fsym =
    pred_sym
      (if is_static then
         Sym.fresh (Fulminate.Utils.static_prefix filename ^ "_" ^ Sym.pp_string sym)
       else
         sym)
  in
  let args =
    match List.assoc Sym.equal sym sigma.declarations with
    | _, _, Decl_function (_, _, args, _, _, _) ->
      let arg_names = AT.get_computational at in
      let arg_cts = List.map (fun (_, ct, _) -> ct) args in
      List.map (fun ((x, bt), ct) -> (x, (bt, ct))) (List.combine arg_names arg_cts)
    | _ -> failwith ("unreachable @ " ^ __LOC__)
  in
  let globals =
    let global_syms =
      let args = args |> List.map fst in
      at
      |> AT.get_lat
      |> LAT.free_vars (fun _ -> Sym.Set.empty)
      |> Sym.Set.to_seq
      |> List.of_seq
      |> List.filter (fun x ->
        not
          (List.mem (fun x y -> String.equal (Sym.pp_string x) (Sym.pp_string y)) x args))
    in
    List.map
      (fun sym ->
         match List.assoc Sym.equal sym prog5.globs with
         | GlobalDecl sct -> (sym, sct)
         | GlobalDef (sct, _) -> (sym, sct))
      global_syms
  in
  let new_args = List.map (fun (x, _) -> (x, Sym.fresh (Sym.pp_string x ^ "_cn"))) args in
  let bs1 =
    List.map
      (fun (x, y) ->
         Utils.create_binding y (bt_to_ctype (fst (List.assoc Sym.equal x args))))
      new_args
  in
  let ss1 =
    List.map
      (fun (x, y) ->
         A.AilSdeclaration
           [ ( y,
               Some
                 (mk_expr
                    (CtA.wrap_with_convert_to
                       (A.AilEident x)
                       (fst (List.assoc Sym.equal x args)))) )
           ])
      new_args
  in
  let lat =
    LAT.subst
      (fun _ x -> x)
      (IT.make_subst
         (List.map
            (fun (x, y) ->
               (x, IT.sym_ (y, fst (List.assoc Sym.equal x args), Locations.other __LOC__)))
            new_args))
      (AT.get_lat at)
  in
  (* Generate function *)
  let bs2, ss2 = compile_lat filename sigma prog5 lat in
  let bs3, ss3 =
    let bs, ss =
      (args |> List.map_snd snd |> List.map (fun x -> (false, x)))
      @ (globals |> List.map (fun (x, ct) -> (true, (x, Sctypes.to_ctype ct))))
      |> List.map (fun (global, (arg, ct)) ->
        let arg_str_sym = Sym.fresh (Sym.pp_string arg ^ "_str") in
        let arg_cast_str_sym = Sym.fresh (Sym.pp_string arg ^ "_cast_str") in
        let bt =
          Memory.bt_of_sct (Sctypes.of_ctype_unsafe (Locations.other __LOC__) ct)
        in
        let fsym = Sym.fresh ("cn_replicate_owned_" ^ string_of_ctype ct ^ "_aux") in
        let type_str =
          Pp.plain (Sctypes.pp (Sctypes.of_ctype_unsafe (Locations.other __LOC__) ct))
        in
        let b_arg = [ Utils.create_binding arg_str_sym C.pointer_to_char ] in
        let s_arg =
          A.
            [ (let e_var =
                 match Sym.description arg with
                 | SD_ObjectAddress _ ->
                   AilEunary
                     ( Indirection,
                       mk_expr
                         (AilEcall
                            ( mk_expr
                                (AilEident
                                   (Sym.fresh (Fulminate.Globals.getter_str filename arg))),
                              [] )) )
                 | _ -> AilEident arg
               in
               AilSdeclaration
                 [ ( arg_str_sym,
                     Some
                       (mk_expr
                          (AilEcall
                             ( mk_expr (AilEident fsym),
                               [ mk_expr
                                   (CtA.wrap_with_convert_to
                                      (match bt with
                                       | Loc () -> e_var
                                       | _ -> AilEunary (Address, mk_expr e_var))
                                      (BT.Loc ()))
                               ] ))) )
                 ])
            ]
        in
        let b_cast, s_cast =
          sprintf_to_buf
            arg_cast_str_sym
            [ "(" ^ type_str ^ ")("; "%s"; ")" ]
            [ Sym.pp_string arg_str_sym ]
        in
        let s_add =
          A.
            [ AilSexpr
                (mk_expr
                   (AilEcall
                      ( mk_expr (AilEident (Sym.fresh "cn_replicate_owned")),
                        [ mk_expr
                            (AilEstr
                               ( None,
                                 [ ( Locations.other __LOC__,
                                     [ (if global then "" else type_str ^ " ")
                                       ^ Sym.pp_string arg
                                     ] )
                                 ] ));
                          mk_expr (AilEident arg_cast_str_sym)
                        ] )))
            ]
        in
        (b_arg @ b_cast, s_arg @ s_cast @ s_add))
      |> List.split
    in
    let s_call =
      A.
        [ AilSexpr
            (mk_expr
               (AilEcall
                  ( mk_expr (AilEident (Sym.fresh "cn_replica_lines_append")),
                    [ mk_expr
                        (AilEstr
                           ( None,
                             [ ( Locations.other __LOC__,
                                 [ Sym.pp_string sym
                                   ^ "("
                                   ^ (args
                                      |> List.map fst
                                      |> List.map (fun x -> Sym.pp_string x)
                                      |> String.concat ", ")
                                   ^ ");"
                                 ] )
                             ] ))
                    ] )))
        ]
    in
    (List.flatten bs, List.flatten ss @ s_call)
  in
  let decl : A.sigma_declaration =
    ( fsym,
      ( Locations.other __LOC__,
        Attrs [],
        Decl_function
          ( false,
            (C.no_qualifiers, C.void),
            List.map (fun (_, (_, ct)) -> (C.no_qualifiers, ct, false)) args,
            false,
            false,
            false ) ) )
  in
  let def : CF.GenTypes.genTypeCategory A.sigma_function_definition =
    ( fsym,
      ( Locations.other __LOC__,
        0,
        Attrs [],
        List.map fst args,
        A.(mk_stmt (AilSblock (bs1 @ bs2 @ bs3, List.map mk_stmt (ss1 @ ss2 @ ss3)))) ) )
  in
  (decl, def)


let synthesize
      filename
      (sigma : CF.GenTypes.genTypeCategory A.sigma)
      (prog5 : unit Mucore.file)
      (insts : (bool * Fulminate.Extract.instrumentation) list)
  : (A.sigma_declaration * CF.GenTypes.genTypeCategory A.sigma_function_definition) list
  =
  (* Per type *)
  let type_replicators =
    let module CtypeSet =
      Set.Make (struct
        type t = C.ctype

        let compare a b = String.compare (string_of_ctype a) (string_of_ctype b)
      end)
    in
    let module SctypesSet = Set.Make (Sctypes) in
    let arg_types =
      insts
      |> List.map snd
      |> List.filter (fun (inst : Fulminate.Extract.instrumentation) ->
        Option.is_some inst.internal)
      |> List.filter_map (fun (inst : Fulminate.Extract.instrumentation) ->
        match List.assoc Sym.equal inst.fn sigma.declarations with
        | _, _, Decl_function (_, _, cts, _, _, _) ->
          Some (List.map (fun (_, ct, _) -> ct) cts)
        | _ -> None)
      |> List.flatten
    in
    let types_of_interest =
      let rec expand scts =
        let old_scts = scts in
        let new_scts =
          scts
          |> SctypesSet.to_seq
          |> List.of_seq
          |> List.concat_map (fun sct ->
            match sct with
            | Sctypes.Array (sct', Some _) -> [ sct; sct' ]
            | Sctypes.Struct tag ->
              (match Pmap.find tag prog5.tagDefs with
               | StructDef pieces ->
                 let member_scts =
                   pieces
                   |> List.filter_map
                        (fun ({ member_or_padding; _ } : Memory.struct_piece) ->
                           member_or_padding)
                   |> List.map snd
                 in
                 sct :: member_scts
               | _ -> [ sct ])
            | _ -> [ sct ])
          |> SctypesSet.of_list
        in
        if SctypesSet.equal old_scts new_scts then old_scts else expand new_scts
      in
      !CtA.ownership_ctypes @ arg_types
      |> CtypeSet.of_list
      |> CtypeSet.to_seq
      |> List.of_seq
      |> List.map (Sctypes.of_ctype_unsafe (Locations.other __LOC__))
      |> SctypesSet.of_list
      |> expand
      |> SctypesSet.to_seq
      |> List.of_seq
    in
    List.map (compile_sct_aux prog5) types_of_interest
    @ List.map compile_sct types_of_interest
  in
  (* Per predicate *)
  let pred_replicators =
    prog5.resource_predicates
    |> List.map (fun (sym, pred) -> compile_pred filename sigma prog5 sym pred)
  in
  (* Per specification *)
  let spec_replicators =
    insts
    |> List.filter_map
         (fun ((is_static, inst) : bool * Fulminate.Extract.instrumentation) ->
            Option.map
              (fun lat -> compile_spec filename sigma prog5 is_static inst.fn lat)
              inst.internal)
  in
  type_replicators @ pred_replicators @ spec_replicators
