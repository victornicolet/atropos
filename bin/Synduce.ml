open Lang
open Base
open Getopt
open Fmt
open Parsers
module Config = Lib.Utils.Config

let parse_only = ref false

let print_usage () =
  pf stdout "Usage : Synduce [options] input_file@.";
  pf stdout
    "Options:\n\
    \    -h --help                      Print this message.\n\
    \    -d --debug                     Print debugging info.\n\
    \    -v --verbose                   Print verbose.\n\
    \    -i --info-off                  Print timing information only.\n\
    \    -o --output=PATH               Output solution in folder PATH.\n\
    \  Otimizations off/on:\n\
    \    -s --no-splitting              Do not split systems into subsystems.\n\
    \       --no-syndef                 Do not use syntactic definitions.\n\
    \    -t --no-detupling              Turn off detupling.\n\
    \    -c --simple-init               Initialize T naively.\n\
    \       --acegis                    Use the Abstract CEGIS algorithm. Turns bmc on.\n\
    \       --ccegis                    Use the Concrete CEGIS algorithm. Turns bmc on.\n\
    \       --no-simplify               Don't simplify equations with partial evaluation.\n\
    \       --no-gropt                  Don't optimize grammars.\n\
    \    -u --no-check-unrealizable     Do not check if synthesis problems are functionally \
     realizable.\n\
    \  Bounded checking:\n\
    \       --use-bmc                   Use acegis bounded model checking (bmc mode).\n\
    \    -b --bmc=MAX_DEPTH             Maximum depth of terms for bounded model checking, in bmc \
     mode.\n\
    \    -n --verification=NUM          Number of expand calls for bounded model checking, in opt \
     mode.\n\
    \  Background solver parameters:\n\
    \       --ind-tlimit=TIMEOUT        Set the solver to timeout after TIMEOUT ms when doing an \
     induction proof.\n\
    \  Debugging:\n\
    \  -I   --interactive               Request additional lemmas interactively.\n\
    \  -L   --interactive-loop          Request lemmas interactively in a loop.\n\
    \       --parse-only                Just parse the input.\n\
    \       --show-vars                 Print variables and their types at the end.\n\
     -> Try:\n\
     ./Synduce benchmarks/list/mps.ml@.";
  Caml.exit 0

let options =
  [
    ('b', "bmc", None, Some Config.set_check_depth);
    ('c', "simple-init", set Config.simple_init true, None);
    ('C', "no-check-unrealizable", set Config.check_unrealizable false, None);
    ('d', "debug", set Config.debug true, None);
    ('h', "help", Some print_usage, None);
    ('i', "info-off", set Config.info false, None);
    ('I', "interactive", set Config.interactive_lemmas true, None);
    ('L', "interactive-loop", set Config.interactive_lemmas_loop true, None);
    ('n', "verification", None, Some Config.set_num_expansions_check);
    ('o', "output", None, Some Config.set_output_folder);
    ('s', "no-splitting", set Config.split_solve_on false, None);
    ('t', "no-detupling", set Config.detupling_on false, None);
    ('v', "verbose", set Config.verbose true, None);
    ('\000', "acegis", set Config.use_acegis true, None);
    ('\000', "ccegis", set Config.use_ccegis true, None);
    ('\000', "parse-only", set parse_only true, None);
    ('\000', "no-gropt", set Config.optimize_grammars false, None);
    ('\000', "no-simplify", set Config.simplify_eqns false, None);
    ('\000', "no-syndef", set Config.use_syntactic_definitions false, None);
    ('\000', "show-vars", set Config.show_vars true, None);
    ('\000', "use-bmc", set Config.use_bmc true, None);
    (* Background solver parameters *)
    ('\000', "ind-tlimit", None, Some Config.set_induction_proof_tlimit);
    ('\000', "use-dryadsynth", set Syguslib.Solvers.SygusSolver.default_solver DryadSynth, None);
  ]

let main () =
  let filename = ref None in
  parse_cmdline options (fun s -> filename := Some s);
  let filename = match !filename with Some f -> ref f | None -> print_usage () in
  set_style_renderer stdout `Ansi_tty;
  Caml.Format.set_margin 100;
  (match !Syguslib.Solvers.SygusSolver.default_solver with
  | CVC4 -> ()
  | EUSolver -> failwith "EUSolver unsupported."
  | DryadSynth -> Syguslib.Sygus.use_v1 := true);
  let start_time = Unix.gettimeofday () in
  Config.glob_start := start_time;
  (* Parse input file. *)
  let is_ocaml_syntax = Caml.Filename.check_suffix !filename ".ml" in
  let prog, psi_comps = if is_ocaml_syntax then parse_ocaml !filename else parse_pmrs !filename in
  let _ = seek_types prog in
  let all_pmrs =
    try translate prog
    with e ->
      if !Config.show_vars then Term.Variable.print_summary stdout ();
      raise e
  in
  if !parse_only then Caml.exit 1;
  (match Algo.PmrsAlgos.solve_problem psi_comps all_pmrs with
  | Ok target ->
      let elapsed = Unix.gettimeofday () -. start_time in
      let verif_ratio = 100.0 *. (!Config.verif_time /. elapsed) in
      Utils.Log.info
        Fmt.(
          fun frmt () ->
            pf frmt "Solution found in %4.4fs (%3.1f%% verifying):@.%a@]" elapsed verif_ratio
              (box (Algo.AState.pp_soln ~use_ocaml_syntax:is_ocaml_syntax))
              target);
      (* If output specified, write the solution in file. *)
      (match Config.get_output_file !filename with
      | Some out_file ->
          Utils.Log.to_file out_file (fun frmt () ->
              (box (Algo.AState.pp_soln ~use_ocaml_syntax:is_ocaml_syntax)) frmt target)
      | None -> ());
      (* If no info required, output timing information. *)
      if not !Config.info then (
        Fmt.(pf stdout "%i,%.4f,%.4f@." !Algo.AState.refinement_steps !Config.verif_time elapsed);
        Fmt.(pf stdout "success@."))
  | Error _ -> Utils.Log.error_msg "No solution found.");
  if !Config.show_vars then Term.Variable.print_summary stdout ()

;;
main ()
