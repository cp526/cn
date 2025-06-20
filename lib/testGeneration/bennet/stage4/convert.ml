module CF = Cerb_frontend
module A = CF.AilSyntax
module BT = BaseTypes
module IT = IndexTerms
module LC = LogicalConstraints
module GA = GenAnalysis
module SymGraph = Graph.Persistent.Digraph.Concrete (Sym)
module StringMap = Map.Make (String)

let bennet = Sym.fresh "bennet"

let transform_gt (gt : Stage3.Term.t) : Term.t =
  let rec aux (vars : Sym.t list) (path_vars : Sym.Set.t) (gt : Stage3.Term.t) : Term.t =
    let last_var = match vars with v :: _ -> v | [] -> bennet in
    match gt with
    | Uniform { bt } -> Uniform { bt }
    | Pick { bt; choices } ->
      let choice_var = Sym.fresh_anon () in
      Pick
        { bt;
          choice_var;
          choices =
            (let choices =
               let gcd =
                 List.fold_left
                   (fun x y -> Z.gcd x y)
                   (fst (List.hd choices))
                   (List.map fst (List.tl choices))
               in
               List.map_fst (fun x -> Z.div x gcd) choices
             in
             let w_sum = List.fold_left Z.add Z.zero (List.map fst choices) in
             let max_int = Z.of_int Int.max_int in
             let f =
               if Z.leq w_sum max_int then
                 fun w -> Z.to_int w
               else
                 fun w ->
               Z.to_int
                 (Z.max Z.one (Z.div w (Z.div (Z.add w_sum (Z.pred max_int)) max_int)))
             in
             List.map
               (fun (w, gt) ->
                  (f w, aux (choice_var :: vars) (Sym.Set.add choice_var path_vars) gt))
               choices);
          last_var
        }
    | Alloc -> Alloc
    | Call { fsym; iargs; oarg_bt; sized } ->
      Call { fsym; iargs; oarg_bt; path_vars; sized }
    | Asgn { addr; sct; value; rest } ->
      let rec pointer_of (it : IT.t) =
        match it with
        | IT (ArrayShift { base; _ }, _, _) -> pointer_of base
        | IT (Sym x, _, _) | IT (Cast (_, IT (Sym x, _, _)), _, _) -> x
        | _ ->
          let pointers =
            addr
            |> IT.free_vars_bts
            |> Sym.Map.filter (fun _ bt -> BT.equal bt (BT.Loc ()))
            |> Sym.Map.bindings
            |> List.map fst
            |> Sym.Set.of_list
          in
          if not (Sym.Set.cardinal pointers == 1) then
            Cerb_debug.print_debug 2 [] (fun () ->
              Pp.(
                plain
                  (braces
                     (separate_map
                        (comma ^^ space)
                        Sym.pp
                        (List.of_seq (Sym.Set.to_seq pointers)))
                   ^^^ !^" in "
                   ^^ IT.pp addr)));
          if Sym.Set.is_empty pointers then (
            print_endline (Pp.plain (IT.pp it));
            failwith __LOC__);
          Sym.Set.choose pointers
      in
      Asgn
        { pointer = pointer_of addr;
          addr;
          sct;
          value;
          last_var;
          rest = aux vars path_vars rest
        }
    | LetStar { x; x_bt; value; rest } ->
      LetStar
        { x;
          x_bt;
          value = aux vars path_vars value;
          last_var;
          rest = aux (x :: vars) path_vars rest
        }
    | Return { value } -> Return { value }
    | Assert { prop; rest } -> Assert { prop; last_var; rest = aux vars path_vars rest }
    | ITE { bt; cond; t; f } ->
      let path_vars = Sym.Set.union path_vars (IT.free_vars cond) in
      ITE { bt; cond; t = aux vars path_vars t; f = aux vars path_vars f }
    | Map { i; bt; perm; inner } ->
      let i_bt, _ = BT.map_bt bt in
      let min, max = IndexTerms.Bounds.get_bounds (i, i_bt) perm in
      Map { i; bt; min; max; perm; inner = aux (i :: vars) path_vars inner; last_var }
  in
  aux [] Sym.Set.empty gt


let transform_gd ({ filename; recursive; spec; name; iargs; oargs; body } : Stage3.Def.t)
  : Def.t
  =
  { filename; recursive; spec; name; iargs; oargs; body = body |> transform_gt }


let transform (ctx : Stage3.Ctx.t) : Ctx.t = List.map_snd transform_gd ctx
