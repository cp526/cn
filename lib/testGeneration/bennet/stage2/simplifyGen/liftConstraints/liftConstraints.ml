let transform_gt (gt : Term.t) =
  Cerb_debug.print_debug 2 [] (fun () -> "lift_constraints");
  gt
  |> Implication.transform_gt
  |> Disjunction.transform_gt
  |> Ite.transform_gt
  |> Let.transform_gt
  |> Conjunction.transform_gt
