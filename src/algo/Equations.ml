open Base
open Lang
open Lang.Term
open AState
open Syguslib.Sygus
open SygusInterface
open SmtInterface
open Smtlib
open Utils
open Either
module SmtI = SmtInterface

type equation = term * term option * term * term

let pp_equation (f : Formatter.t) ((orig, inv, lhs, rhs) : equation) =
  match inv with
  | Some inv ->
      Fmt.(
        pf f "@[<hov 2>E(%a) := @;@[<hov 2>%a %a@;@[%a@;%a@;%a@]@]@]"
          (styled `Italic pp_term)
          orig pp_term inv
          (styled (`Fg `Red) string)
          "=>" pp_term lhs
          (styled (`Fg `Red) string)
          "=" pp_term rhs)
  | None ->
      Fmt.(
        pf f "@[<hov 2>E(%a) := @;@[<hov 2>%a %a %a@]@]"
          (styled `Italic pp_term)
          orig pp_term lhs
          (styled (`Fg `Red) string)
          "=" pp_term rhs)

(* ============================================================================================= *)
(*                        PROJECTION : OPTIMIZATION FOR TUPLES                                   *)
(* ============================================================================================= *)

let mk_projs (targs : RType.t list) (tl : RType.t list) (xi : Variable.t) =
  let f i t = Variable.mk ~t:(Some (RType.fun_typ_pack targs t)) (xi.vname ^ Int.to_string i) in
  List.mapi ~f tl

let projection_eqns (lhs : term) (rhs : term) =
  match (lhs.tkind, rhs.tkind) with
  | TTup lhs_tl, TTup rhs_tl -> List.map ~f:(fun (r, l) -> (r, l)) (List.zip_exn lhs_tl rhs_tl)
  | _ -> [ (lhs, rhs) ]

let invar invariants lhs_e rhs_e =
  let f inv_expr =
    not
      (Set.is_empty
         (Set.inter
            (Set.union (Analysis.free_variables lhs_e) (Analysis.free_variables rhs_e))
            (Analysis.free_variables inv_expr)))
  in
  let conjs = List.filter ~f (Set.elements invariants) in
  mk_assoc Binop.And conjs

let proj_and_detuple_eqns (projections : (int, variable list, Int.comparator_witness) Map.t)
    (eqns : equation list) =
  let apply_p = Analysis.apply_projections projections in
  let f (t, pre, lhs, rhs) =
    let lhs' = apply_p lhs and rhs' = apply_p rhs in
    let eqs = projection_eqns lhs' rhs' in
    List.map ~f:(fun (_l, _r) -> (t, pre, _l, _r)) eqs
  in
  List.concat (List.map ~f eqns)

let proj_unknowns (unknowns : VarSet.t) =
  let unknowns_projs, new_unknowns =
    let f (l, vs) xi =
      match Variable.vtype_or_new xi with
      | RType.TFun _ -> (
          let targs, tout = RType.fun_typ_unpack (Variable.vtype_or_new xi) in
          match tout with
          | TTup tl ->
              let new_vs = mk_projs targs tl xi in
              (l @ [ (xi, Some new_vs) ], Set.union vs (VarSet.of_list new_vs))
          | _ -> (l @ [ (xi, None) ], Set.add vs xi))
      | _ -> (l @ [ (xi, None) ], Set.add vs xi)
    in
    List.fold ~f ~init:([], VarSet.empty) (Set.elements unknowns)
  in
  let proj_map =
    let mmap =
      Map.of_alist
        (module Int)
        (List.map
           ~f:(fun (x, p) -> (x.vid, p))
           (* Only select relevant xi for projection *)
           (List.filter_map
              ~f:(fun (_x, _o) -> match _o with Some o -> Some (_x, o) | None -> None)
              unknowns_projs))
    in
    match mmap with `Ok x -> x | `Duplicate_key _ -> failwith "Unexpected error while projecting."
  in
  (new_unknowns, proj_map)

(* ============================================================================================= *)
(*                               CHECKING UNREALIZABILITY                                        *)
(* ============================================================================================= *)

type unrealizability_ctex =
  VarSet.t * (int, term, Int.comparator_witness) Map.t * (int, term, Int.comparator_witness) Map.t
(** A counterexample to realizability is a pair of models: a pair of maps from variable ids to terms. *)

let pp_unrealizability_ctex (frmt : Formatter.t) ((ctxt, m, m') : unrealizability_ctex) : unit =
  let pp_model frmt model =
    (* Print as comma-separated list of variable -> term *)
    Fmt.(list ~sep:comma (pair ~sep:Utils.rightarrow (option pp_variable) pp_term))
      frmt
      (List.map ~f:(fun (vid, t) -> (VarSet.find_by_id ctxt vid, t)) (Map.to_alist model))
  in
  Fmt.(pf frmt "@[M = [%a]@]@;@[M' = [%a]@]" pp_model m pp_model m')

(** Check if system of equations defines a functionally realizable synthesis problem.
  If any equation defines an unsolvable problem, an unrealizability_ctex is added to the
  list of counterexamples to be returned.
  If the returned list is empty, the problem may be solvable/realizable.
  If the returned list is not empty, the problem is not solvable / unrealizable.
*)
let check_unrealizable (unknowns : VarSet.t) (eqns : equation list) : unrealizability_ctex list =
  Log.info (fun f () -> Fmt.(pf f "Checking unrealizability..."));
  let start_time = Unix.gettimeofday () in
  let solver = Solvers.make_z3_solver () in
  Solvers.load_min_max_defs solver;
  (* Main part of the check, appliued to each equation in eqns. *)
  let check_eqn_accum ctexs (_, precond, lhs, rhs) =
    let vset =
      Set.diff (Set.union (Analysis.free_variables lhs) (Analysis.free_variables rhs)) unknowns
    in
    let var_subst = VarSet.prime vset in
    let vset' = VarSet.of_list (List.map ~f:snd var_subst) in
    let sub = List.map ~f:(fun (v, v') -> (mk_var v, mk_var v')) var_subst in
    (* Extract the arguments of the rhs, if it is a call to an unknown. *)
    let maybe_rhs_args =
      match rhs.tkind with
      | TApp ({ tkind = TVar f_v; _ }, args) ->
          if Set.mem unknowns f_v then
            let fv_args = VarSet.union_list (List.map ~f:Analysis.free_variables args) in
            (* Check there are no unknowns in the args. *)
            if Set.are_disjoint fv_args unknowns then Some args else None
          else None
      | _ -> None
    in
    match maybe_rhs_args with
    | None -> ctexs (* If we cannot match the expected structure, skip it. *)
    | Some rhs_args ->
        (* Building the constraints *)
        let preconds = Option.map ~f:(fun pre -> (pre, substitution sub pre)) precond in
        (* Checking. *)
        Solvers.spush solver;
        (* Declare the variables. *)
        Solvers.declare_all solver (decls_of_vars (Set.union vset vset'));
        (* Assert preconditions, if not none. *)
        (match preconds with
        | Some (pre, pre') ->
            Solvers.smt_assert solver (smt_of_term pre);
            Solvers.smt_assert solver (smt_of_term pre')
        | None -> ());
        (* The lhs must be different. **)
        let lhs_diff = mk_un Not (mk_bin Eq lhs (substitution sub lhs)) in
        Solvers.smt_assert solver (smt_of_term lhs_diff);
        (* The rhs must be equal. *)
        List.iter rhs_args ~f:(fun rhs_arg_term ->
            let rhs_eq = mk_bin Eq rhs_arg_term (substitution sub rhs_arg_term) in
            Solvers.smt_assert solver (smt_of_term rhs_eq));
        let new_ctexs =
          match Solvers.check_sat solver with
          | Sat -> (
              match Solvers.get_model solver with
              | SExps s ->
                  let model = model_to_constmap (SExps s) in
                  let m0, m0' =
                    Map.partitioni_tf
                      ~f:(fun ~key ~data:_ -> Option.is_some (VarSet.find_by_name vset key))
                      model
                  in
                  (* Remap the names to ids of the original variables in m' *)
                  let m, m' =
                    List.fold var_subst
                      ~init:(Map.empty (module Int), Map.empty (module Int))
                      ~f:(fun (m, m') (v, v') ->
                        Variable.free v';
                        ( (match Map.find m0 v.vname with
                          | Some data -> Map.set m ~key:v.vid ~data
                          | None -> m),
                          match Map.find m0' v'.vname with
                          | Some data -> Map.set m' ~key:v.vid ~data
                          | None -> m' ))
                  in

                  (vset, m, m') :: ctexs
              | _ -> ctexs)
          | _ -> ctexs
        in
        Solvers.spop solver;
        new_ctexs
  in
  let ctexs = List.fold ~f:check_eqn_accum ~init:[] eqns in
  Solvers.close_solver solver;
  let elapsed = Unix.gettimeofday () -. start_time in
  Log.info (fun f () -> Fmt.(pf f "... finished in %3.4fs" elapsed));
  Log.debug (fun f () ->
      match ctexs with
      | [] -> Fmt.pf f "No counterexample to realizability found."
      | _ :: _ ->
          Fmt.(
            pf f "Counterexamples found:@;@[<hov 2>%a@]"
              (list ~sep:sp pp_unrealizability_ctex)
              ctexs));
  ctexs

(* ============================================================================================= *)
(*                               BUILDING SYSTEMS OF EQUATIONS                                   *)
(* ============================================================================================= *)

let check_equation ~(p : psi_def) ((_, pre, lhs, rhs) : equation) : bool =
  (match (Expand.nonreduced_terms_all p lhs, Expand.nonreduced_terms_all p rhs) with
  | [], [] -> true
  | _ -> false)
  &&
  match pre with
  | None -> true
  | Some t -> ( match Expand.nonreduced_terms_all p t with [] -> true | _ -> false)

(**
   Compute the left hand side of an equation of p from term t.
   The result is a maximally reduced term with some applicative
   terms of the form (p.orig x) where x is a variable.
*)
let compute_lhs p t =
  let t' = Reduce.reduce_pmrs p.repr t in
  let r_t = Expand.replace_rhs_of_main p p.repr t' in
  let subst_params =
    let l = List.zip_exn p.orig.pargs p.target.pargs in
    List.map l ~f:(fun (v1, v2) -> (mk_var v1, mk_var v2))
  in
  let f_r_t = Reduce.reduce_pmrs p.orig r_t in
  let final = substitution subst_params f_r_t in
  Expand.replace_rhs_of_mains p (Reduce.reduce_term final)

let remap_rec_calls p t =
  let g = p.target in
  let t' = Expand.replace_rhs_of_main p g t in
  let f a _t =
    match _t.tkind with
    | TApp ({ tkind = TVar x; _ }, args) ->
        if a && Variable.equal x g.pmain_symb then
          match args with [ arg ] -> First (compute_lhs p arg) | _ -> Second a
        else if Set.mem g.psyntobjs x then Second true
        else Second a
    | _ -> Second a
  in
  let res = rewrite_accum ~init:false ~f t' in
  if Term.term_equal res t' then t (* Don't revert step taken before *) else res

let compute_rhs_with_replacing p t =
  let g = p.target in
  let custom_reduce x =
    let one_step t0 =
      let rstep = ref false in
      let rewrite_rule _t =
        match _t.tkind with
        | TApp ({ tkind = TVar f; _ }, fargs) -> (
            match Reduce.rule_lookup g.prules f fargs with
            | [] -> None
            | hd :: _ ->
                let hd' = remap_rec_calls p hd in
                rstep := true;
                Some hd')
        (* Replace recursive calls to g by calls to f circ g,
           if recursive call appear under unknown. *)
        | _ -> None
      in
      let t0' = rewrite_top_down rewrite_rule t0 in
      (t0', !rstep)
    in
    Reduce.until_irreducible one_step x
  in
  let app_t = mk_app (mk_var g.pmain_symb) [ t ] in
  let t' = Reduce.reduce_term (custom_reduce app_t) in
  let _res = Expand.replace_rhs_of_mains p t' in
  _res

let compute_rhs ?(force_replace_off = false) p t =
  if not force_replace_off then compute_rhs_with_replacing p t
  else
    let res = Expand.replace_rhs_of_mains p (Reduce.reduce_term (Reduce.reduce_pmrs p.target t)) in
    res

let make ?(force_replace_off = false) ~(p : psi_def) (tset : TermSet.t) : equation list =
  let eqns =
    let fold_f eqns t =
      let lhs = compute_lhs p t in
      let rhs = compute_rhs ~force_replace_off p t in
      eqns @ [ (t, lhs, rhs) ]
    in
    Set.fold ~init:[] ~f:fold_f tset
  in
  let all_subs, invariants =
    Expand.subst_recursive_calls p
      (List.concat (List.map ~f:(fun (_, lhs, rhs) -> [ lhs; rhs ]) eqns))
  in
  if Set.length invariants > 0 then
    Log.verbose
      Fmt.(
        fun frmt () ->
          pf frmt "Invariants:@[<hov 2>%a@]" (list ~sep:comma pp_term) (Set.elements invariants))
  else Log.verbose_msg "No invariants.";
  let pure_eqns =
    let f (t, lhs, rhs) =
      let applic x = substitution all_subs (Reduce.reduce_term (substitution all_subs x)) in
      let lhs' = Reduce.reduce_term (applic lhs) and rhs' = Reduce.reduce_term (applic rhs) in
      let lhs'', rhs'' =
        if !Config.simplify_eqns then (Eval.simplify lhs', Eval.simplify rhs') else (lhs', rhs')
      in
      let projs = projection_eqns lhs'' rhs'' in
      List.map ~f:(fun (lhs, rhs) -> (t, invar invariants lhs rhs, lhs, rhs)) projs
    in
    List.concat (List.map ~f eqns)
  in
  let eqns_with_invariants =
    let f (t, inv, lhs, rhs) =
      let env =
        VarSet.to_env
          (Set.diff
             (Set.union (Analysis.free_variables lhs) (Analysis.free_variables rhs))
             p.target.psyntobjs)
      in
      Log.info (fun frmt () ->
          Fmt.pf frmt "Please provide a constraint for \"@[%a@]\"." pp_equation (t, inv, lhs, rhs));
      match Stdio.In_channel.input_line Stdio.stdin with
      | None | Some "" ->
          Log.info (fun frmt () -> Fmt.pf frmt "No additional constraint provided.");
          (t, inv, lhs, rhs)
      | Some x -> (
          let sexpr = Sexplib.Sexp.of_string x in
          let smtterm = Smtlib.SmtLib.smtTerm_of_sexp sexpr in
          let pred_term = SmtInterface.term_of_smt env in
          let term x =
            match inv with
            | None -> pred_term x
            | Some inv ->
                { tpos = inv.tpos; tkind = TBin (Binop.And, inv, pred_term x); ttyp = inv.ttyp }
          in
          match smtterm with None -> (t, inv, lhs, rhs) | Some x -> (t, Some (term x), lhs, rhs))
    in
    if !Config.interactive_lemmas then List.map ~f pure_eqns else pure_eqns
  in
  Log.verbose (fun f () ->
      let print_less = List.take eqns_with_invariants !Config.pp_eqn_count in
      Fmt.(
        pf f "Equations > make (%i) @." (Set.length tset);
        List.iter ~f:(fun eqn -> Fmt.pf f "@[%a@]@." pp_equation eqn) print_less));

  match List.find ~f:(fun eq -> not (check_equation ~p eq)) eqns_with_invariants with
  | Some not_pure ->
      Log.error_msg Fmt.(str "Not pure: %a" pp_equation not_pure);
      failwith "Equation not pure."
  | None -> eqns_with_invariants

let revert_projs (orig_xi : VarSet.t)
    (projections : (int, variable list, Int.comparator_witness) Map.t)
    (soln : (string * variable list * term) list) : (string * variable list * term) list =
  (* Helper functions *)
  let find_soln s = List.find_exn ~f:(fun (s', _, _) -> String.equal s.vname s') soln in
  let join_bodies main_args first_body rest =
    let f accum (_, args, body) =
      let subst =
        match List.zip args main_args with
        | Ok l -> List.map l ~f:(fun (v1, v2) -> (mk_var v1, mk_var v2))
        | Unequal_lengths -> failwith "Projections should have same number of arguments."
      in
      accum @ [ substitution subst body ]
    in
    let tuple_elts = List.fold ~f ~init:[ first_body ] rest in
    mk_tup tuple_elts
  in
  (* Helper sets *)
  let all_proj_names, xi_projected =
    let x0 = Map.to_alist projections in
    let x1 = List.concat (List.map ~f:(fun (id, l) -> List.map ~f:(fun e -> (id, e)) l) x0) in
    ( List.map ~f:(fun (_, v) -> v.vname) x1,
      VarSet.of_list (List.filter_map ~f:(fun (id, _) -> VarSet.find_by_id orig_xi id) x1) )
  in
  let _, rest =
    let f (s, _, _) = List.mem all_proj_names ~equal:String.equal s in
    List.partition_tf ~f soln
  in
  (* Build for each xi projected *)
  let new_xi_solns =
    let f xi =
      let vls = Map.find_exn projections xi.vid in
      let solns = List.map ~f:find_soln vls in
      match solns with
      | [] -> failwith "revert_projs : failed to find an expected solution."
      | [ (_, args, body) ] -> (xi.vname, args, body) (* This should not happen though. *)
      | (_, args1, body1) :: tl -> (xi.vname, args1, join_bodies args1 body1 tl)
    in
    List.map ~f (Set.elements xi_projected)
  in
  rest @ new_xi_solns

(* ============================================================================================= *)
(*                               SOLVING SYSTEMS OF EQUATIONS                                    *)
(* ============================================================================================= *)

let pp_soln (f : Formatter.t) soln =
  Fmt.(
    list ~sep:comma (fun fmrt (s, args, bod) ->
        match args with
        | [] -> pf fmrt "@[<hov 2>@[%s@] = @[%a@]@]" s pp_term bod
        | _ ->
            pf fmrt "@[<hov 2>@[%s(%a)@] = @[%a@]@]" s (list ~sep:comma Variable.pp) args pp_term
              bod))
    f soln

let combine ?(verb = false) prev_sol new_response =
  match (prev_sol, new_response) with
  | Some soln, (resp, Some soln') ->
      if verb then Log.debug_msg Fmt.(str "Partial solution:@;@[<hov 2>%a@]" pp_soln soln');
      (resp, Some (soln @ soln'))
  | _, (resp, None) -> (resp, None)
  | None, (resp, _) -> (resp, None)

let solve_syntactic_definitions (unknowns : VarSet.t) (eqns : equation list) =
  (* Are all arguments free? *)
  let ok_rhs_args _args =
    let arg_vars = VarSet.union_list (List.map ~f:Analysis.free_variables _args) in
    Set.is_empty (Set.inter unknowns arg_vars)
  in
  (* Is lhs, args a full definition of the function? *)
  let ok_lhs_args lhs args =
    let argv = List.map args ~f:ext_var_or_none in
    let argset = VarSet.of_list (List.concat (List.filter_opt argv)) in
    if
      List.for_all ~f:Option.is_some argv
      && Set.is_empty (Set.diff (Analysis.free_variables lhs) argset)
    then
      let args = List.filter_opt argv in
      if List.length (List.concat args) = Set.length argset then Some args else None
    else None
  in
  (* Make a function out of lhs of equation constraint using args. *)
  let mk_lam lhs args =
    let pre_subst =
      List.map args ~f:(fun arg_tuple ->
          let t =
            match arg_tuple with
            | [ v ] -> Variable.vtype_or_new v
            | l -> RType.TTup (List.map ~f:Variable.vtype_or_new l)
          in
          let v = Variable.mk ~t:(Some t) (Alpha.fresh ()) in
          match arg_tuple with
          | [ arg ] -> (v, [ (mk_var arg, mk_var v) ])
          | l -> (v, List.mapi l ~f:(fun i arg -> (mk_var arg, mk_sel (mk_var v) i))))
    in
    let new_args, subst = List.unzip pre_subst in
    (new_args, Reduce.reduce_term (substitution (List.concat subst) lhs))
  in
  let full_defs, other_eqns =
    let f (t, inv, lhs, rhs) =
      match (inv, rhs.tkind) with
      | _, TApp ({ tkind = TVar x; _ }, args) when Set.mem unknowns x && ok_rhs_args args -> (
          match ok_lhs_args lhs args with
          | Some argv ->
              let lam_args, lam_body = mk_lam lhs argv in
              Either.First (x, (lam_args, lam_body))
          | None -> Either.Second (t, inv, lhs, rhs))
      | _ -> Either.Second (t, inv, lhs, rhs)
    in
    List.partition_map ~f eqns
  in
  let resolved = VarSet.of_list (List.map ~f:Utils.first full_defs) in
  let new_eqns =
    let substs =
      List.map full_defs ~f:(fun (x, (lhs_args, lhs_body)) ->
          let t, _ = infer_type (mk_fun (List.map ~f:(fun x -> PatVar x) lhs_args) lhs_body) in
          (mk_var x, t))
    in
    List.map other_eqns ~f:(fun (t, inv, lhs, rhs) ->
        let new_lhs = Reduce.reduce_term (substitution substs lhs) in
        let new_rhs = Reduce.reduce_term (substitution substs rhs) in
        (t, inv, new_lhs, new_rhs))
  in
  let partial_soln =
    List.map ~f:(fun (x, (lhs_args, lhs_body)) -> (x.vname, lhs_args, lhs_body)) full_defs
  in
  if List.length partial_soln > 0 then
    Log.debug_msg Fmt.(str "Syntactic definition:@;@[<hov 2>%a@]" pp_soln partial_soln);
  (partial_soln, Set.diff unknowns resolved, new_eqns)

let synthfuns_of_unknowns ?(bools = false) ?(eqns = []) ?(ops = OpSet.empty) (unknowns : VarSet.t) =
  let xi_formals (xi : variable) : sorted_var list * sygus_sort =
    let tv = Variable.vtype_or_new xi in
    let targs, tout = RType.fun_typ_unpack tv in
    (sorted_vars_of_types targs, sort_of_rtype tout)
  in
  let f xi =
    let args, ret_sort = xi_formals xi in
    let guess = if !Config.optimize_grammars then Grammars.make_guess eqns xi else None in
    let grammar = Grammars.generate_grammar ~guess ~bools ops args ret_sort in
    CSynthFun (xi.vname, args, ret_sort, grammar)
  in
  List.map ~f (Set.elements unknowns)

let constraints_of_eqns (eqns : equation list) : command list =
  let detupled_equations =
    let f (_, pre, lhs, rhs) =
      let eqs = projection_eqns lhs rhs in
      List.map ~f:(fun (_l, _r) -> (pre, _l, _r)) eqs
    in
    List.concat (List.map ~f eqns)
  in
  let eqn_to_constraint (pre, lhs, rhs) =
    match pre with
    | Some precondition ->
        CConstraint
          (SyApp
             ( IdSimple "or",
               [
                 SyApp (IdSimple "not", [ sygus_of_term precondition ]);
                 SyApp (IdSimple "=", [ sygus_of_term lhs; sygus_of_term rhs ]);
               ] ))
    | None -> CConstraint (SyApp (IdSimple "=", [ sygus_of_term lhs; sygus_of_term rhs ]))
  in
  List.map ~f:eqn_to_constraint detupled_equations

let solve_eqns (unknowns : VarSet.t) (eqns : equation list) =
  let aux_solve () =
    let free_vars, all_operators, has_ite =
      let f (fvs, ops, hi) (_, _, lhs, rhs) =
        ( VarSet.union_list [ fvs; Analysis.free_variables lhs; Analysis.free_variables rhs ],
          Set.union ops (Set.union (Grammars.operators_of lhs) (Grammars.operators_of rhs)),
          hi || Analysis.has_ite lhs || Analysis.has_ite rhs )
      in
      let fvs, ops, hi =
        List.fold eqns ~f ~init:(VarSet.empty, Set.empty (module Operator), false)
      in
      (Set.diff fvs unknowns, ops, hi)
    in
    (* Commands *)
    let set_logic = CSetLogic (Grammars.logic_of_operator all_operators) in
    let synth_objs = synthfuns_of_unknowns ~bools:has_ite ~eqns ~ops:all_operators unknowns in
    let sort_decls = declare_sorts_of_vars free_vars in
    let var_decls = List.map ~f:declaration_of_var (Set.elements free_vars) in
    let constraints = constraints_of_eqns eqns in
    let extra_defs =
      (if Set.mem all_operators (Binary Max) then [ max_definition ] else [])
      @ if Set.mem all_operators (Binary Min) then [ min_definition ] else []
    in
    let commands =
      set_logic :: (extra_defs @ sort_decls @ synth_objs @ var_decls @ constraints @ [ CCheckSynth ])
    in
    (* Call the solver. *)
    let handle_response (resp : solver_response) =
      let parse_synth_fun (fname, fargs, _, fbody) =
        let args =
          let f (varname, sort) = Variable.mk ~t:(rtype_of_sort sort) varname in
          List.map ~f fargs
        in
        let local_vars = VarSet.of_list args in
        let body, _ = infer_type (term_of_sygus (VarSet.to_env local_vars) fbody) in
        (fname, args, body)
      in
      match resp with
      | RSuccess resps ->
          let soln = List.map ~f:parse_synth_fun resps in
          (resp, Some soln)
      | RInfeasible -> (RInfeasible, None)
      | RFail -> (RFail, None)
      | RUnknown -> (RUnknown, None)
    in
    match Syguslib.Solvers.SygusSolver.solve_commands commands with
    | Some resp -> handle_response resp
    | None -> (RFail, None)
  in
  if !Config.check_unrealizable then
    match check_unrealizable unknowns eqns with [] -> aux_solve () | _ :: _ -> (RInfeasible, None)
  else aux_solve ()

let solve_eqns_proxy (unknowns : VarSet.t) (eqns : equation list) =
  if !Config.syndef_on then
    let partial_soln, new_unknowns, new_eqns = solve_syntactic_definitions unknowns eqns in
    if Set.length new_unknowns > 0 then
      combine (Some partial_soln) (solve_eqns new_unknowns new_eqns)
    else (RSuccess [], Some partial_soln)
  else solve_eqns unknowns eqns

(* Solve the trivial equations first, avoiding the overhead from the
   sygus solver.
*)
let solve_constant_eqns (unknowns : VarSet.t) (eqns : equation list) =
  let constant_soln, other_eqns =
    let f (t, inv, lhs, rhs) =
      match rhs.tkind with
      | TVar x when Set.mem unknowns x ->
          (* TODO check that lhs is a constant term. (Should be the case if wf) *)
          Either.first (x, lhs)
      | _ -> Either.Second (t, inv, lhs, rhs)
    in
    List.partition_map ~f eqns
  in
  let resolved = VarSet.of_list (List.map ~f:Utils.first constant_soln) in
  let new_eqns =
    let substs = List.map ~f:(fun (x, lhs) -> (mk_var x, lhs)) constant_soln in
    List.map other_eqns ~f:(fun (t, inv, lhs, rhs) ->
        (t, inv, substitution substs lhs, substitution substs rhs))
  in
  let partial_soln = List.map ~f:(fun (x, lhs) -> (x.vname, [], lhs)) constant_soln in
  if List.length partial_soln > 0 then
    Log.debug_msg Fmt.(str "Constant:@;@[<hov 2>%a@]" pp_soln partial_soln);
  (partial_soln, Set.diff unknowns resolved, new_eqns)

let split_solve partial_soln (unknowns : VarSet.t) (eqns : equation list) =
  (* If an unknown depends only on itself, it can be split from the rest *)
  let split_eqn_systems =
    let f (l, u, e) xi =
      (* Separate in set of equation where u appears and rest *)
      let eqn_u, rest =
        List.partition_tf e ~f:(fun (_, _, lhs, rhs) ->
            let fv = Set.union (Analysis.free_variables lhs) (Analysis.free_variables rhs) in
            Set.mem fv xi)
      in
      let eqn_only_u, eqn_u =
        List.partition_tf eqn_u ~f:(fun (_, _, lhs, rhs) ->
            let fv = Set.union (Analysis.free_variables lhs) (Analysis.free_variables rhs) in
            Set.is_empty (Set.inter fv (Set.diff unknowns (VarSet.singleton xi))))
      in
      match eqn_u with
      | [] ->
          Log.debug_msg Fmt.(str "Synthesize %s independently." xi.vname);
          (l @ [ (VarSet.singleton xi, eqn_only_u) ], u, rest)
      | _ -> (l, Set.add u xi, e)
    in
    let sl, u, e = List.fold (Set.elements unknowns) ~f ~init:([], VarSet.empty, eqns) in
    sl @ [ (u, e) ]
  in
  let solve_eqn_aux prev_resp prev_sol u e =
    if Set.length u > 0 then combine ~verb:true prev_sol (solve_eqns_proxy u e)
    else (prev_resp, prev_sol)
  in
  List.fold split_eqn_systems ~init:(RSuccess [], Some partial_soln)
    ~f:(fun (prev_resp, prev_sol) (u, e) -> solve_eqn_aux prev_resp prev_sol u e)

let solve_stratified (unknowns : VarSet.t) (eqns : equation list) =
  let psol, u, e =
    if !Config.syndef_on then
      let c_soln, no_c_unknowns, no_c_eqns = solve_constant_eqns unknowns eqns in
      let partial_soln', new_unknowns, new_eqns =
        solve_syntactic_definitions no_c_unknowns no_c_eqns
      in
      (c_soln @ partial_soln', new_unknowns, new_eqns)
    else ([], unknowns, eqns)
  in
  if !Config.split_solve_on then split_solve psol u e
  else
    match solve_eqns u e with
    | resp, Some soln -> (resp, Some (psol @ soln))
    | resp, None -> (resp, None)

let solve ~(p : psi_def) (eqns : equation list) =
  let unknowns = p.target.psyntobjs in
  let soln_final =
    if !Config.detupling_on then
      let new_unknowns, projections = proj_unknowns p.target.psyntobjs in
      let new_eqns = proj_and_detuple_eqns projections eqns in
      match solve_stratified new_unknowns new_eqns with
      | resp, Some soln0 ->
          let soln =
            if Map.length projections > 0 then revert_projs unknowns projections soln0 else soln0
          in
          (resp, Some soln)
      | resp, None -> (resp, None)
    else solve_stratified unknowns eqns
  in
  (match soln_final with
  | _, Some soln -> Utils.Log.debug_msg Fmt.(str "@[<hov 2>Solution found: @;%a" pp_soln soln)
  | _ -> ());
  soln_final
