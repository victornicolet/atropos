open Base
open Lang
open Lang.Term
open Utils
open AState
open Syguslib.Sygus

let loop_counter = ref 0
(* ============================================================================================= *)
(*                                                                                               *)
(* ============================================================================================= *)
let rec refinement_loop (p : psi_def) (t_set, u_set : TermSet.t * TermSet.t) =
  Int.incr loop_counter;
  Log.info (fun frmt () -> Fmt.pf frmt "Refinement step %i." !loop_counter);
  Log.debug_msg Fmt.(str "Start refinement loop with (t,u) = %a, %a"
                       pp_term_set t_set pp_term_set u_set);
  let eqns = Equations.make ~p t_set in
  let s_resp, solution = Equations.solve ~p eqns in
  match s_resp, solution with
  | RSuccess _, Some sol ->
    (match Verify.check_solution ~p (t_set, u_set) sol with
     | Some (new_t_set, new_u_set) ->
       Log.debug (fun frmt () ->
           Fmt.(pf frmt "@[<hov 2>Counterexample terms:%a."
                  (list pp_term) (Set.elements (Set.diff new_t_set t_set))));
       refinement_loop p (new_t_set, new_u_set)
     | None ->
       Log.print_ok ();
       let target = PMRS.instantiate_with_solution p.target sol in
       Log.info Fmt.(fun frmt () -> pf frmt "@[<hov 2>Solution found:@;%a@]" PMRS.pp target))
  | RFail, _ -> Log.error_msg "SyGuS solver failed to find a solution."; Log.fatal ()
  | RInfeasible, _ ->
    (Log.info
       Fmt.(fun frmt () ->
           pf frmt "@[<hov 2>This problem has no solution. Counterexample set:@;%a@]"
             (list ~sep:sp pp_term) (Set.elements t_set));
     Caml.exit 0)
  | RUnknown, _  -> Log.error_msg "SyGuS solver returned unknown."; Log.fatal ()
  | _ -> failwith "Unreachable."



let psi (p : psi_def) =
  let mgts = MGT.most_general_terms p.target in
  Log.debug
    (fun frmt () -> Fmt.(pf frmt "@[<hov 2>MGT() = %a@]"
                           (list ~sep:comma
                              (parens (pair ~sep:comma (pair ~sep:comma int int) (option pp_term))))
                           mgts));
  (* Initialize sets with the most general terms. *)
  let t_set, u_set =
    List.fold mgts ~init:(TermSet.empty, TermSet.empty)
      ~f:(fun (t,u) (_, mgt_opt) ->
          match mgt_opt with
          | None -> t,u
          | Some term ->
            let t1, t2 = Expand.maximal p term in
            Set.union t t1, Set.union u t2)
  in
  if Set.is_empty t_set then
    Log.error_msg "Empty set of terms for equation system."
  else
    (loop_counter := 0;
     refinement_loop p (t_set, u_set))


(* ============================================================================================= *)
(*                                                 MAIN ENTRY POINTS                             *)
(* ============================================================================================= *)

let no_synth () = failwith "No synthesis objective found."

let solve_problem (pmrs : (string, PMRS.t, Base.String.comparator_witness) Map.t) : unit =
  let orig_fname = "spec" and target_fname = "target" and repr_fname = "repr" in
  (* Representation function. *)
  let repr, theta_to_tau =
    match Map.find pmrs repr_fname with
    | Some pmrs -> Either.First pmrs, Variable.vtype_or_new pmrs.pmain_symb
    | None ->
      let reprs = Hashtbl.filter ~f:(fun (v, _, _) -> String.(v.vname = repr_fname)) Term._globals in
      (match Hashtbl.choose reprs with
       | Some (_,(f,a,b)) -> Either.Second (f,a,b), Variable.vtype_or_new f
       | None -> Log.error_msg "No representation function given."; no_synth ())
  in
  (* Original function. *)
  let orig_f, tau =
    match Map.find pmrs orig_fname with
    | Some pmrs -> pmrs, pmrs.pinput_typ
    | None -> Log.error_msg "No origin function found."; no_synth ()
  in
  (* Target recursion scheme. *)
  let target_f, xi, theta =
    let target_f =
      match Map.find pmrs target_fname with
      | Some pmrs -> pmrs
      | None -> Log.error_msg "No target recursion scheme found"; no_synth ()
    in
    target_f, target_f.pparams, target_f.pinput_typ
  in
  (* Match origin and target recursion scheme types. *)
  (match theta_to_tau with
   | RType.TFun (TTup [theta'], tau')
   | RType.TFun (theta', tau') ->
     let sb1 = RType.unify_one theta theta' in
     let sb2 = RType.unify_one tau tau' in
     (match sb1, sb2 with
      | Some sb1, Some sb2 ->
        (match RType.unify (RType.mkv (sb1 @ sb2)) with
         | Some sb' -> Term.Variable.update_var_types (RType.mkv sb')
         | None -> Log.error_msg "Could not unify θ and τ in problem definition."; Log.fatal ())
      | _ ->
        Log.error_msg
          (Fmt.str "repr has type %a, expected %a." RType.pp theta_to_tau RType.pp RType.(TFun(theta, tau)));
        Log.fatal ())

   | _ -> Log.error_msg "Representation function should be a function."; Log.fatal ());
  Term.(
    let orig_out = Variable.vtype_or_new orig_f.pmain_symb in
    let target_out = Variable.vtype_or_new target_f.pmain_symb in
    Log.debug_msg Fmt.(str "ɑ : unify %a and %a" RType.pp orig_out RType.pp target_out);
    match orig_out, target_out with
    | TFun(_, tout), TFun(_, tout') ->
      (match RType.unify_one tout tout' with
       | Some subs -> Variable.update_var_types (RType.mkv subs)
       | None -> Log.error_msg "Failed to unify output types."; no_synth ())
    |_ -> Log.error_msg "Original or target is not a function."; no_synth ());
  (*  Update the type of all the components. *)
  let repr =
    match repr with
    | Either.First pmrs -> Either.First (PMRS.infer_pmrs_types pmrs)
    | Either.Second (f,a,b) ->
      let b', _ = Term.infer_type b in Either.Second (f, a, b')
  in
  let target_f = PMRS.infer_pmrs_types target_f in
  let orig_f = PMRS.infer_pmrs_types orig_f in
  let theta = target_f.pinput_typ in
  let t_out =
    Term.(match Variable.vtype_or_new orig_f.pmain_symb with
        | TFun(_, tout) -> tout
        | _ -> failwith "Unexpected.")
  in
  (* Print summary information about the problem. *)
  Log.info
    Fmt.(fun fmt () -> pf fmt " Ψ (%a) := ∀ x : %a. (%s o %s)(x) = %s(x)"
            (list ~sep:comma Term.Variable.pp) (Set.elements xi) RType.pp theta
            orig_fname repr_fname target_fname);
  Log.info Fmt.(fun fmt () -> pf fmt "%a" PMRS.pp orig_f);
  Log.info Fmt.(fun fmt () -> pf fmt "%a" PMRS.pp target_f);
  Log.info Fmt.(fun fmt () ->
      match repr with
      | Either.First pmrs -> pf fmt "%a" PMRS.pp pmrs
      | Either.Second (fv, args, body) ->
        pf fmt "%s(%a) = %a" fv.vname
          (list ~sep:comma Term.pp_fpattern) args Term.pp_term body);
  let repr_pmrs =
    match repr with
    | Either.First p -> p
    | Either.Second (f,a,b) -> PMRS.func_to_pmrs f a b
  in
  (* Set global information. *)
  AState._tau := tau;
  AState._theta := theta;
  AState._alpha := t_out;
  (* Solve the problem. *)
  psi { target = target_f; orig =  orig_f; repr =  repr_pmrs }
