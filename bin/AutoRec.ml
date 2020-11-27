open Base
open Getopt
open Fmt
open Parsers

module Config = Lib.Utils.Config

let options = [
  ('v', "verbose", (set Config.verbose true), None);
]

let main () =
  let filename = ref "" in
  parse_cmdline options (fun s -> filename := s);
  set_style_renderer stdout `Ansi_tty;
  Caml.Format.set_margin 100;
  let prog = parse_pmrs !filename in
  let _ = seek_types prog in
  let plist = translate prog in
  List.iter plist ~f:(fun p -> pf stdout "%a@." Lang.PMRScheme.pp_pmrs p)
;;
main ()