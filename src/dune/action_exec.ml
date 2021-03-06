open! Stdune
open Import
open Fiber.O

type exec_context =
  { context : Context.t option
  ; purpose : Process.purpose
  }

type exec_environment =
  { working_dir : Path.t
  ; env : Env.t
  ; stdout_to : Process.Io.output Process.Io.t
  ; stderr_to : Process.Io.output Process.Io.t
  ; stdin_from : Process.Io.input Process.Io.t
  }

let exec_run ~ectx ~eenv prog args =
  ( match ectx.context with
  | None
   |Some { Context.for_host = None; _ } ->
    ()
  | Some ({ Context.for_host = Some host; _ } as target) ->
    let invalid_prefix prefix =
      match Path.descendant prog ~of_:prefix with
      | None -> ()
      | Some _ ->
        User_error.raise
          [ Pp.textf "Context %s has a host %s." target.name host.name
          ; Pp.textf "It's not possible to execute binary %s in it."
            (Path.to_string_maybe_quoted prog)
          ; Pp.nop
          ; Pp.text "This is a bug and should be reported upstream."
          ]
    in
    invalid_prefix (Path.relative Path.build_dir target.name);
    invalid_prefix (Path.relative Path.build_dir ("install/" ^ target.name)) );
  Process.run Strict ~dir:eenv.working_dir ~env:eenv.env
    ~stdout_to:eenv.stdout_to ~stderr_to:eenv.stderr_to
    ~stdin_from:eenv.stdin_from ~purpose:ectx.purpose prog args

let exec_echo stdout_to str =
  Fiber.return (output_string (Process.Io.out_channel stdout_to) str)

let rec exec t ~ectx ~eenv =
  match (t : Action.t) with
  | Run (Error e, _) -> Action.Prog.Not_found.raise e
  | Run (Ok prog, args) -> exec_run ~ectx ~eenv prog args
  | Chdir (dir, t) -> exec t ~ectx ~eenv:{ eenv with working_dir = dir }
  | Setenv (var, value, t) ->
    exec t ~ectx ~eenv:{ eenv with env = Env.add eenv.env ~var ~value }
  | Redirect_out (Stdout, fn, Echo s) ->
    Io.write_file (Path.build fn) (String.concat s ~sep:" ");
    Fiber.return ()
  | Redirect_out (outputs, fn, t) ->
    let fn = Path.build fn in
    redirect_out t ~ectx ~eenv outputs fn
  | Redirect_in (inputs, fn, t) -> redirect_in t ~ectx ~eenv inputs fn
  | Ignore (outputs, t) -> redirect_out t ~ectx ~eenv outputs Config.dev_null
  | Progn ts -> exec_list ts ~ectx ~eenv
  | Echo strs -> exec_echo eenv.stdout_to (String.concat strs ~sep:" ")
  | Cat fn ->
    Io.with_file_in fn ~f:(fun ic ->
      Io.copy_channels ic (Process.Io.out_channel eenv.stdout_to));
    Fiber.return ()
  | Copy (src, dst) ->
    let dst = Path.build dst in
    Io.copy_file ~src ~dst ();
    Fiber.return ()
  | Symlink (src, dst) ->
    ( if Sys.win32 then
      let dst = Path.build dst in
      Io.copy_file ~src ~dst ()
    else
      let src =
        match Path.Build.parent dst with
        | None -> Path.to_string src
        | Some from ->
          let from = Path.build from in
          Path.reach ~from src
      in
      let dst = Path.Build.to_string dst in
      match Unix.readlink dst with
      | target ->
        if target <> src then (
          (* @@DRA Win32 remove read-only attribute needed when symlinking
            enabled *)
          Unix.unlink dst;
          Unix.symlink src dst
        )
      | exception _ -> Unix.symlink src dst );
    Fiber.return ()
  | Copy_and_add_line_directive (src, dst) ->
    Io.with_file_in src ~f:(fun ic ->
      Path.build dst
      |> Io.with_file_out ~f:(fun oc ->
        let fn = Path.drop_optional_build_context_maybe_sandboxed src in
        output_string oc
          (Utils.line_directive ~filename:(Path.to_string fn) ~line_number:1);
        Io.copy_channels ic oc));
    Fiber.return ()
  | System cmd ->
    let path, arg =
      Utils.system_shell_exn ~needed_to:"interpret (system ...) actions"
    in
    exec_run ~ectx ~eenv path [ arg; cmd ]
  | Bash cmd ->
    exec_run ~ectx ~eenv
      (Utils.bash_exn ~needed_to:"interpret (bash ...) actions")
      [ "-e"; "-u"; "-o"; "pipefail"; "-c"; cmd ]
  | Write_file (fn, s) ->
    Io.write_file (Path.build fn) s;
    Fiber.return ()
  | Rename (src, dst) ->
    Unix.rename (Path.Build.to_string src) (Path.Build.to_string dst);
    Fiber.return ()
  | Remove_tree path ->
    Path.rm_rf (Path.build path);
    Fiber.return ()
  | Mkdir path ->
    if Path.is_in_build_dir path then
      Path.mkdir_p path
    else
      Code_error.raise "Action_exec.exec: mkdir on non build dir"
        [ ("path", Path.to_dyn path) ];
    Fiber.return ()
  | Digest_files paths ->
    let s =
      let data =
        List.map paths ~f:(fun fn ->
          (Path.to_string fn, Cached_digest.file fn))
      in
      Digest.generic data
    in
    exec_echo eenv.stdout_to (Digest.to_string_raw s)
  | Diff ({ optional; file1; file2; mode } as diff) ->
    let remove_intermediate_file () =
      if optional then
        try Path.unlink file2 with Unix.Unix_error (ENOENT, _, _) -> ()
    in
    if Diff.eq_files diff then (
      remove_intermediate_file ();
      Fiber.return ()
    ) else
      let is_copied_from_source_tree file =
        match Path.extract_build_context_dir_maybe_sandboxed file with
        | None -> false
        | Some (_, file) -> Path.exists (Path.source file)
      in
      Fiber.finalize
        (fun () ->
          if mode = Binary then
            User_error.raise
              [ Pp.textf "Files %s and %s differ."
                (Path.to_string_maybe_quoted file1)
                  (Path.to_string_maybe_quoted file2)
              ]
          else
            Print_diff.print file1 file2
              ~skip_trailing_cr:(mode = Text && Sys.win32))
        ~finally:(fun () ->
          ( match optional with
          | false ->
            if
              is_copied_from_source_tree file1
              && not (is_copied_from_source_tree file2)
            then
              Promotion.File.register_dep
                ~source_file:
                  (snd
                    (Option.value_exn
                      (Path.extract_build_context_dir_maybe_sandboxed file1)))
                ~correction_file:(Path.as_in_build_dir_exn file2)
          | true ->
            if is_copied_from_source_tree file1 then
              Promotion.File.register_intermediate
                ~source_file:
                  (snd
                    (Option.value_exn
                      (Path.extract_build_context_dir_maybe_sandboxed file1)))
                ~correction_file:(Path.as_in_build_dir_exn file2)
            else
              remove_intermediate_file () );
          Fiber.return ())
  | Merge_files_into (sources, extras, target) ->
    let lines =
      List.fold_left
        ~init:(String.Set.of_list extras)
        ~f:(fun set source_path ->
          Io.lines_of_file source_path
          |> String.Set.of_list |> String.Set.union set)
        sources
    in
    let target = Path.build target in
    Io.write_lines target (String.Set.to_list lines);
    Fiber.return ()

and redirect_out t ~ectx ~eenv outputs fn =
  let out = Process.Io.file fn Process.Io.Out in
  let stdout_to, stderr_to =
    match outputs with
    | Stdout -> (out, eenv.stderr_to)
    | Stderr -> (eenv.stdout_to, out)
    | Outputs -> (out, out)
  in
  exec t ~ectx ~eenv:{ eenv with stdout_to; stderr_to }
  >>| fun () -> Process.Io.release out

and redirect_in t ~ectx ~eenv inputs fn =
  let in_ = Process.Io.file fn Process.Io.In in
  let stdin_from =
    match inputs with
    | Stdin -> in_
  in
  exec t ~ectx ~eenv:{ eenv with stdin_from }
  >>| fun () -> Process.Io.release in_

and exec_list ts ~ectx ~eenv =
  match ts with
  | [] -> Fiber.return ()
  | [ t ] -> exec t ~ectx ~eenv
  | t :: rest ->
    let* () =
      let stdout_to = Process.Io.multi_use eenv.stdout_to in
      let stderr_to = Process.Io.multi_use eenv.stderr_to in
      let stdin_from = Process.Io.multi_use eenv.stdin_from in
      exec t ~ectx ~eenv:{ eenv with stdout_to; stderr_to; stdin_from }
    in
    exec_list rest ~ectx ~eenv

let exec ~targets ~context ~env t =
  let env =
    match ((context : Context.t option), env) with
    | _, Some e -> e
    | None, None -> Env.initial
    | Some c, None -> c.env
  in
  let purpose = Process.Build_job targets in
  let ectx = { purpose; context }
  and eenv =
    { working_dir = Path.root
    ; env
    ; stdout_to = Process.Io.stdout
    ; stderr_to = Process.Io.stderr
    ; stdin_from = Process.Io.stdin
    }
  in
  exec t ~ectx ~eenv
