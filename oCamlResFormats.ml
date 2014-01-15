(* This file is part of ocp-ocamlres - directory scanning
 * (C) 2013 OCamlPro - Benjamin CANOU
 *
 * ocp-ocamlres is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 2 of the License, or
 * (at your option) any later version.
 *
 * ocp-ocamlres is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with ocp-ocamlres.  If not, see <http://www.gnu.org/licenses/>. *)

open OCamlRes.Path
open OCamlRes.Res
open PPrint

(** The type of format plug-ins *)
module type Format = sig
  (** A short dexcription for the help page *)
  val info : string
  (** Pretty print a resource store to a PPrint document *)
  val output : string root -> unit
  (** The list of specific arguments *)
  val options : (Arg.key * Arg.spec * Arg.doc) list
end

(** A global registry for format plug-ins *)
let formats : (string * (module Format)) list ref = ref []
    
(** Register a new named format module or override one. *)
let register name (format : (module Format)) =
  formats := (name, format) :: !formats

(** Find an format module from its name. *)
let find name : (module Format) =
  List.assoc name !formats

(** Retrive the currently available formats *)
let formats () =
  List.map
    (fun (name, m) ->
       let module M = (val m : Format) in
       name, M.info, M.options)
    !formats

(** Splits a string into a flow of escaped characters. Respects
    the original line feeds if it ressembles a text file. *)
let format_string width data =
  let len = String.length data in
  let looks_like_text =
    let rec loop i acc =
      if i = len then
        acc <= len / 10 (* allow 10% of escaped chars *)
      else
        let c = Char.code data.[i] in
        if c < 32 && c <> 10 && c <> 13 && c <> 9 then false
        else if Char.code data.[i] >= 128 then loop (i + 1) (acc + 1)
        else loop (i + 1) acc
    in loop 0 0
  in
  let  hexd = [| '0' ; '1' ; '2' ; '3' ; '4' ; '5' ; '6' ; '7' ;
                 '8' ; '9' ; 'A' ; 'B' ; 'C' ; 'D' ; 'E' ; 'F' |] in
  if not looks_like_text then
    column
      (fun col ->
         let cwidth = (width - col) / 4 in
         let rec split acc ofs =
           if ofs >= len then List.rev acc
           else
             let blen = min cwidth (len - ofs) in
             let blob = String.create (blen * 4) in
             for i = 0 to blen - 1 do
               let c = Char.code data.[ofs + i] in
               blob.[i * 4] <- '\\' ;
               blob.[i * 4 + 1] <- 'x' ;
               blob.[i * 4 + 2] <- (hexd.(c lsr 4)) ;
               blob.[i * 4 + 3] <- (hexd.(c land 15)) ;
             done ;
             let blob = if ofs <> 0 then !^" " ^^ !^blob else !^blob in
             split (blob :: acc) (ofs + blen)
         in
         !^"\"" ^^ separate (!^"\\" ^^ hardline) (split [] 0)) ^^ !^"\""
  else
    let do_one_char cur next =
      match cur, next with
      | ' ', _ ->
        group (ifflat !^" " (!^"\\" ^^ hardline ^^ !^"\\ "))
      | '\r', '\n' ->
        group (ifflat !^"\\r" (!^"\\" ^^ hardline ^^ !^" \\r"))
      | '\r', ' ' ->
        ifflat !^"\\r"
          (group (ifflat !^"\\r" (!^"\\" ^^ hardline ^^ !^" \\r"))
              ^^ !^"\\" ^^ hardline ^^ !^"\\")
      | '\r', _ ->
        ifflat !^"\\r"
          (group (ifflat !^"\\r" (!^"\\" ^^ hardline ^^ !^" \\r"))
           ^^ !^"\\" ^^ hardline ^^ !^" ")
      | '\n', ' ' ->
        ifflat !^"\\n"
          (group (ifflat !^"\\n" (!^"\\" ^^ hardline ^^ !^" \\n"))
           ^^ !^"\\" ^^ hardline ^^ !^"\\")
      | '\n', _ ->
        ifflat !^"\\n"
          (group (ifflat !^"\\n" (!^"\\" ^^ hardline ^^ !^" \\n"))
           ^^ !^"\\" ^^ hardline ^^ !^" ")
      | '\t', _ ->
        group (ifflat !^"\\t" (!^"\\" ^^ hardline ^^ !^" \\t"))
      | '"', _ ->
        group (ifflat !^"\\\"" (!^"\\" ^^ hardline ^^ !^" \\\""))
      | '\\', _ ->
        group (ifflat !^"\\\\" (!^"\\" ^^ hardline ^^ !^" \\\\"))
      | c, _ ->
        let fmt =
          if Char.code c > 128 || Char.code c < 32 then
            let c = Char.code c in
            let s = String.create 4 in
            s.[0] <- '\\' ; s.[1] <- 'x' ;
            s.[2] <- (hexd.(c lsr 4)) ; s.[3] <- (hexd.(c land 15)) ;
            s
          else String.make 1 c
        in
        group (ifflat !^fmt (!^"\\" ^^ hardline ^^ !^" " ^^ !^fmt))
    in
    let res = ref empty in
    for i = 0 to len - 2 do
      res := !res ^^ do_one_char data.[i] data.[succ i]
    done ;
    if len > 0 then res := !res ^^ do_one_char data.[len - 1] '\000' ;
    group (!^"\"" ^^ !res ^^ !^"\"")

(** Produces OCaml source with OCaml submodules for directories and
    OCaml value definitions for files, with customizable mangling. *)
module Static = struct
  open OCamlResSubFormats
  let width = ref 80

  let esc name =
    let res = String.copy name in
    for i = 0 to String.length name - 1 do
      match name.[i] with
      | '0' .. '9' | '_' | 'a' .. 'z' | 'A'..'Z' -> ()
      | _ -> res.[i] <- '_'
    done ;
    res

  let esc_name name =
    if name = "" then "void" else
      let res = esc name in
      match name.[0] with
      | 'A'..'Z' | '0' .. '9' -> "_" ^ res
      | _ -> res

  let esc_dir name =
    if name = "" then "Void" else
      let res = esc name in
      match name.[0] with
      | '0' .. '9' -> "M_" ^ res
      | '_' -> "M" ^ res
      | 'a'..'z' -> String.capitalize res
      | _ -> res

  let output root =
    let sfs = OCamlResSubFormats.handled_subformats () in
    let rec output node =
      match node with
      | Error msg ->
        !^"(* Error: " ^^ !^ msg ^^ !^ " *)"
      | Dir (name, nodes) ->
        group (!^"module " ^^ !^(esc_dir name) ^^ !^" = struct"
               ^^ nest 2 (break 1
                          ^^ separate_map (break 1) output nodes)
               ^^ break 1 ^^ !^"end")
      | File (name, data) ->
        try
          match OCamlRes.Path.split_ext name with
          | _, None -> raise Not_found
          | name, Some ext ->
            let module F = (val (SM.find ext sfs) : SubFormat) in
            group (!^"let " ^^ !^(esc_name name) ^^ !^" ="
                   ^^ nest 2 (break 1 ^^ F.pprint (F.parse data)))
        with Not_found ->
          let name = fst (OCamlRes.Path.split_ext name) in
            group (!^"let " ^^ !^(esc_name name) ^^ !^" ="
                   ^^ nest 2 (break 1 ^^ format_string !width data))
    in
    let res = separate_map (break 1) (fun node -> output node) root in
    PPrint.ToChannel.pretty 0.8 80 stdout (res ^^ hardline)

  let info = "produces static ocaml bindings (modules for dirs, values for files)"
  let options =
    OCamlResSubFormats.options
    @ [ "-width", Set_int width,
        "set the maximum chars per line of generated code" ]
end
  
let _ = register "static" (module Static)

(** Produces OCaml source contaiming a single [root] value which
    contains an OCamlRes tree to be used at runtime through the
    OCamlRes module. *)
module Res = struct
  let use_variants = ref true
  let width = ref 80

  let output root =
    let sfs = OCamlResSubFormats.handled_subformats () in
    let prefix, box =
      let rec collect acc = function
        | Dir (name, nodes) ->
          List.fold_left collect acc nodes
        | Error _ -> acc
        | File (name, data) ->
          try
            match OCamlRes.Path.split_ext name with
            | _, None -> raise Not_found
            | name, Some ext ->
              let module F = (val (SM.find ext sfs)) in
              SM.add F.name F.ty acc
          with Not_found -> SM.add "raw" "string" acc
      in
      match SM.bindings (List.fold_left collect SM.empty root) with
      | [] | [ _ ] -> empty, false
      | l ->
        (if not !use_variants then
           group (!^"type content ="
                    ^^ nest 2 (break 1
                               ^^ separate_map (break 1)
                                 (fun (c, t) ->
                                    !^"| " ^^ !^ (String.capitalize c)
                                    ^^ !^" of " ^^ !^t)
                                 l))
         else empty), true
    in
    let cstr ext =
      if not box then ""
      else (if !use_variants then "`" else "") ^ String.capitalize ext ^ " "
    in
    let rec output node =
      match node with
      | Error msg ->
        !^"(* Error: " ^^ !^ msg ^^ !^ " *)"
      | Dir (name, nodes) ->
        let items = separate_map (!^" ;" ^^ break 1) output nodes in
        group (!^"Dir (\"" ^^ !^name ^^ !^"\", ["
               ^^ nest 2 (break 1 ^^ items)
               ^^ !^"])")
      | File (name, data) ->
        let contents =
          try
          match OCamlRes.Path.split_ext name with
          | _, None -> raise Not_found
          | name, Some ext ->
            let module F = (val (SM.find ext sfs)) in
            !^(cstr F.name) ^^ F.pprint (F.parse data)
          with Not_found ->
            !^(cstr "raw") ^^ format_string !width data
        in
        group (!^"File (\"" ^^ !^name ^^ !^"\","
               ^^ nest 2 (break 1 ^^ contents ^^ !^")"))
    in
    let items = (separate_map (!^" ;" ^^ break 1) output root) in
    let res =
      !^"let root = OCamlRes.Res.([" ^^ nest 2 (break 1 ^^ items) ^^ !^"])"
    in
    PPrint.ToChannel.pretty 0.8 80 stdout (res ^^ hardline)

  let info = "produces the OCaml source representation of the OCamlRes tree"
  let options =
    OCamlResSubFormats.options
    @ [ "-no-variants", Arg.Clear use_variants,
        "use a plain sum type instead of polymorphic variants" ;
        "-width", Set_int width,
        "set the maximum chars per line of generated code" ]
end

let _ = register "ocamlres" (module Res)

(** Reproduces the original scanned files (or creates new ones in case
    of a forger resource store). *)
module Files = struct
  let base_output_dir = ref "."

  let output root =
    let rec output base node =
      match node with
      | Error msg ->
        Printf.eprintf "Error: %s\n%!" msg
      | Dir (name, nodes) ->
        let dir = base ^ "/" ^ name in
        Unix.handle_unix_error (Unix.mkdir dir) 0o750 ;
        List.iter (output dir) nodes ;
      | File (name, data) ->
        let chan = open_out_bin (base ^ "/" ^ name) in
        output_string chan data ;
        close_out chan
    in
    if not (Sys.file_exists !base_output_dir) then
      Unix.handle_unix_error (Unix.mkdir !base_output_dir) 0o750 ;
    List.iter
      (fun node -> output !base_output_dir node)
      root

  let info = "reproduces the original files"
  let options = [
    "-output-dir", Arg.Set_string base_output_dir,
    "\"dir\"&set the base output directory (defaults to \".\")"]
end

let _ = register "files" (module Files)
