open Base
open Sygus
open Sexplib
open Lwt_process
open Utils
module OC = Stdio.Out_channel
module IC = Stdio.In_channel

(* Logging utilities. *)
let log_queries = ref true

let solver_verbose = ref false

let err_msg s = Fmt.(pf stderr "[ERROR] %s" s)

let tmp_folder = ref "/tmp"

let log_file () = !tmp_folder ^ "log.sl"

let log_out = ref None

let open_log () = log_out := Some (OC.create (log_file ()))

let log c =
  match !log_out with Some oc -> write_command oc c | None -> err_msg "Failed to open log file."

type solver_instance = { pid : int; inputc : OC.t; outputc : IC.t; decls : String.t Hash_set.t }

let online_solvers : (int * solver_instance) list ref = ref []

let mk_tmp_sl prefix = Caml.Filename.temp_file prefix ".sl"

let commands_to_file (commands : program) (filename : string) =
  let out_chan = OC.create filename in
  let fout = Stdlib.Format.formatter_of_out_channel out_chan in
  Fmt.set_utf_8 fout false;
  Stdlib.Format.pp_set_margin fout 100;
  List.iter commands ~f:(fun c ->
      SyCommand.pp_hum fout c;
      Fmt.(pf fout "@."));
  OC.close out_chan

module SygusSolver = struct
  type t = CVC4 | DryadSynth | EUSolver

  let default_solver = ref CVC4

  let binary_path = function
    | CVC4 -> Config.cvc4_binary_path
    | DryadSynth -> Config.dryadsynth_binary_path
    | EUSolver -> Config.eusolver_binary_path

  let print_options (frmt : Formatter.t) =
    Fmt.(list ~sep:sp (fun fmt opt -> pf fmt "--%s" opt) frmt)

  let fetch_solution filename =
    Log.debug_msg Fmt.(str "Fetching solution in %s" filename);
    reponse_of_sexps (Sexp.input_sexps (Stdio.In_channel.create filename))

  let exec_solver ?(which = !default_solver) ?(options = [])
      ((inputfile, outputfile) : string * string) : solver_response option =
    let command = shell Fmt.(str "%s %a %s" (binary_path which) print_options options inputfile) in
    let out_fd = Unix.openfile outputfile [ Unix.O_RDWR; Unix.O_TRUNC; Unix.O_CREAT ] 0o644 in
    match Lwt_main.run (exec ~stdout:(`FD_move out_fd) command) with
    | Unix.WEXITED 0 -> Some (fetch_solution outputfile)
    | Unix.WEXITED i ->
        Log.error_msg Fmt.(str "Solver exited with code %i." i);
        None
    | Unix.WSIGNALED i ->
        Log.error_msg Fmt.(str "Solver signaled with code %i." i);
        None (* TODO error messages. *)
    | Unix.WSTOPPED i ->
        Log.error_msg Fmt.(str "Solver stopped with code %i." i);
        None

  let wrapped_solver_call ?(which = !default_solver) ?(options = [])
      ((inputfile, outputfile) : string * string) : string * process_out =
    let command = shell Fmt.(str "%s %a %s" (binary_path which) print_options options inputfile) in
    let out_fd = Unix.openfile outputfile [ Unix.O_RDWR; Unix.O_TRUNC; Unix.O_CREAT ] 0o644 in
    (outputfile, open_process_out ~stdout:(`FD_move out_fd) command)

  let exec_solver_parallel (filenames : (string * string) list) =
    let processes = List.map ~f:wrapped_solver_call filenames in
    let proc_status this otf =
      let sol =
        try fetch_solution otf
        with Sys_error s ->
          Log.error_msg Fmt.(str "Sys_error (%a)" string s);
          RFail
      in
      if is_infeasible sol || is_failed sol then None
      else (
        List.iter
          ~f:(fun (_, proc) ->
            if not (equal this#pid proc#pid) then (
              proc#terminate;
              Log.debug_msg Fmt.(str "Killed %a early" int proc#pid)))
          processes;
        Some sol)
    in
    let cp =
      List.map processes ~f:(fun (otf, proc) -> Lwt.map (fun _ -> proc_status proc otf) proc#status)
    in
    Lwt_main.run (Lwt.all cp)

  let solve_commands (p : program) =
    let inputfile = mk_tmp_sl "in_" in
    let outputfile = mk_tmp_sl "out_" in
    Log.debug_msg Fmt.(str "Solving %s -> %s." inputfile outputfile);
    commands_to_file p inputfile;
    exec_solver (inputfile, outputfile)
end
