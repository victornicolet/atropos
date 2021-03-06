open Core
open Term
open Utils

let _MAX = 1000

let until_irreducible f t0 =
  let steps = ref 0 in
  let rec apply_until_irreducible t =
    Int.incr steps;
    let t', reduced = f t in
    if reduced && !steps < _MAX then apply_until_irreducible t' else t'
  in
  apply_until_irreducible t0

(* ============================================================================================= *)
(*                                  TERM REDUCTION                                               *)
(* ============================================================================================= *)
type func_resolution =
  | FRFun of fpattern list * term
  | FRPmrs of PMRS.t
  | FRNonT of PMRS.t
  | FRUnknown

let resolve_func (func : term) =
  match func.tkind with
  | TVar x -> (
      match Hashtbl.find Term._globals x.vname with
      | Some (_, vargs, _, body) -> FRFun (vargs, body)
      | None -> (
          match Hashtbl.find PMRS._globals x.vid with
          | Some pm -> FRPmrs pm
          | None -> (
              match Hashtbl.find PMRS._nonterminals x.vid with
              | Some pm -> FRNonT pm
              | None -> FRUnknown)))
  | TFun (vargs, body) -> FRFun (vargs, body)
  | _ -> FRUnknown

(** Looks for a set of applicable rules in prules to rewrite (f fargs) and return
    the result of applying the possible rules.
    If there is no rule that is applicable, then return an empty list.
*)
let rule_lookup prules (f : variable) (fargs : term list) : term list =
  let app_sub bindv bindto expr =
    let bindt = List.map ~f:mk_var bindv in
    match List.map2 ~f:Utils.pair bindt bindto with Ok x -> Some (substitution x expr) | _ -> None
  in
  let f (nt, rule_args, rule_pat, rhs) =
    if Variable.(nt = f) then
      match rule_pat with
      (* We have a pattern, try to match it. *)
      | Some (cstr, pat_args) -> (
          match (List.last fargs, List.drop_last fargs) with
          | Some pat_match, Some first_args -> (
              match Analysis.matches pat_match ~pattern:(mk_data cstr pat_args) with
              | Some bindto_map ->
                  let bindto_list = Map.to_alist bindto_map in
                  let pat_v, pat_bto = List.unzip bindto_list in
                  app_sub (rule_args @ pat_v) (first_args @ pat_bto) rhs
              | None -> None)
          | _ -> None)
      (* Pattern is empty. Simple substitution. *)
      | None -> app_sub rule_args fargs rhs
    else None
  in
  second (List.unzip (Map.to_alist (Map.filter_map prules ~f)))

(**
  reduce_term reduces a term using only the lambda-calculus
*)
let rec reduce_term (t : term) : term =
  let case f t =
    match t.tkind with
    | TApp (func, args) -> (
        let func' = f func in
        let args' = List.map ~f args in
        match resolve_func func' with
        | FRFun (fpatterns, body) -> (
            match Analysis.subst_args fpatterns args' with
            | Some subst -> Some (substitution subst body)
            | None -> None)
        | FRPmrs pm -> (
            match args' with
            | [ tp ] -> Some (f (reduce_pmrs pm tp))
            | _ -> None (* PMRS are defined only with one argument for now. *))
        | FRNonT p -> Some (pmrs_until_irreducible p t)
        | FRUnknown -> None)
    | TFun ([], body) -> Some (f body)
    | TIte (c, tt, tf) -> (
        match c.tkind with
        (* Resolve constants *)
        | TConst Constant.CFalse -> Some (f tf)
        | TConst Constant.CTrue -> Some (f tt)
        (* Distribute ite on tuples *)
        | _ -> (
            match (tt.tkind, tf.tkind) with
            | TTup tlt, TTup tlf -> (
                match List.zip tlt tlf with
                | Ok zip -> Some (mk_tup (List.map zip ~f:(fun (tt', tf') -> mk_ite c tt' tf')))
                | Unequal_lengths -> None)
            | _, _ -> None))
    | TSel (t, i) -> (
        match f t with { tkind = TTup tl; _ } -> Some (List.nth_exn tl i) | _ -> None)
    | TMatch (t, cases) -> (
        match
          List.filter_opt
            (List.map
               ~f:(fun (p, t') -> Option.map ~f:(fun m -> (m, t')) (Analysis.matches_pattern t p))
               cases)
        with
        | [] -> None
        | (subst_map, rhs_t) :: _ -> Some (substitution (VarMap.to_subst subst_map) rhs_t))
    | _ -> None
  in
  transform ~case t

and pmrs_until_irreducible (prog : PMRS.t) (input : term) =
  let one_step t0 =
    let rstep = ref false in
    let rewrite_rule _t =
      match _t.tkind with
      | TApp ({ tkind = TVar f; _ }, fargs) -> (
          match rule_lookup prog.prules f fargs with
          | [] -> _t
          | hd :: _ ->
              rstep := true;
              hd)
      | _ -> _t
    in
    let t0' = rewrite_with rewrite_rule t0 in
    (t0', !rstep)
  in
  until_irreducible one_step input

and reduce_pmrs (prog : PMRS.t) (input : term) =
  let f_input = mk_app (mk_var prog.pmain_symb) [ input ] in
  reduce_term (pmrs_until_irreducible prog f_input)

(* ============================================================================================= *)
(*                                  DERIVED FROM REDUCTION                                       *)
(* ============================================================================================= *)

let reduce_rules (p : PMRS.t) =
  let reduced_rules =
    let f (nt, args, pat, body) = (nt, args, pat, reduce_term body) in
    Map.map ~f p.prules
  in
  { p with prules = reduced_rules }

let instantiate_with_solution (p : PMRS.t) (soln : (string * variable list * term) list) =
  let xi_set = p.psyntobjs in
  let xi_substs =
    let f (name, args, body) =
      match VarSet.find_by_name xi_set name with
      | Some xi -> (
          match args with
          | [] -> [ (Term.mk_var xi, body) ]
          | _ -> [ (Term.mk_var xi, mk_fun (List.map ~f:(fun x -> FPatVar x) args) body) ])
      | None -> []
    in
    List.concat (List.map ~f soln)
  in
  let target_inst = PMRS.subst_rule_rhs xi_substs ~p in
  reduce_rules target_inst

let is_identity (p : PMRS.t) =
  match p.pinput_typ with
  | [ it ] -> (
      let input_symb = Variable.mk ~t:(Some it) "e" in
      match reduce_pmrs p (mk_var input_symb) with
      | { tkind = TVar x; _ } -> Variable.(x = input_symb)
      | _ -> false)
  | _ -> false
