(** Remote administration library.

    This library allows to define facts about remote machines (targets) by
    executing commands (queries) and then applying changes (operations) to
    realize those facts.

    Queries and ops are performed over ssh, using lib/admin-ssh.py helper
    script. *)

open Printf

(** Aux *)

module SM = struct
  include Map.Make (String)

  let of_json v_of_json =
    (function
     | `Assoc fs ->
         List.fold_left fs
           ~f:(fun acc (k, v) -> add k (v_of_json v) acc)
           ~init:empty
     | json -> Melange_json.of_json_error ~json "expected a JSON object"
      : Yojson.Basic.t -> _ t)

  let to_json v_to_json =
    (fun m ->
       let fs = fold (fun k v acc -> (k, v_to_json v) :: acc) m [] in
       `Assoc fs
      : _ t -> Yojson.Basic.t)
end

let spf = sprintf

(** Command with a description. *)
module Command = struct
  open Melange_json.Primitives

  type t = {
    command : string;
    desc : string option; [@json.option]
    use_sudo : bool;
  }
  [@@deriving to_json]

  type output = { stdout : string list; stderr : string list; exit_code : int }
  [@@deriving of_json]

  let cmd ?(use_sudo = false) ?desc command = { command; desc; use_sudo }

  let to_error out msg =
    spf "command failed: %s\nstdout:\n%s\nstderr:\n%s" msg
      (String.concat ~sep:"\n" out.stdout)
      (String.concat ~sep:"\n" out.stderr)

  let failf out fmt = ksprintf (fun msg -> failwith (to_error out msg)) fmt

  let to_result out msg =
    if out.exit_code = 0 then Ok out else Error (to_error out msg)

  let to_resultf out fmt = ksprintf (to_result out) fmt
end

(** SSH plan/output types *)

(** This is what we pass to lib/admin-ssh.py to execute the plan. *)
module Ssh_plan = struct
  open Melange_json.Primitives
  open Melange_json.To_json

  let add_type_tag tag to_json =
   fun v ->
    match to_json v with
    | `Assoc fs -> `Assoc (("type", string tag) :: fs)
    | _ -> assert false

  type command = Command.t [@@deriving to_json]

  let command_to_json = add_type_tag "command" command_to_json

  type upload = {
    local : string;
    remote : string;
    use_sudo : bool;
    chmod : string option; [@json.option]
    chown : string option; [@json.option]
  }
  [@@deriving to_json]

  let upload_to_json = add_type_tag "upload" upload_to_json

  type upload_content = {
    content : string;
    remote : string;
    use_sudo : bool;
    chmod : string option; [@json.option]
    chown : string option; [@json.option]
  }
  [@@deriving to_json]

  let upload_content_to_json =
    add_type_tag "upload-content" upload_content_to_json

  type task =
    | Upload of upload
    | Upload_content of upload_content
    | Command of command

  let task_to_json (a : task) =
    match a with
    | Upload u -> upload_to_json u
    | Upload_content u -> upload_content_to_json u
    | Command c -> command_to_json c

  type host_plan = {
    username : string option; [@json.option]
    tasks : task list;
  }
  [@@deriving to_json]

  type t = host_plan SM.t [@@deriving to_json]

  module Tasks = Set.Make (struct
    type t = task

    let compare = Ord.poly
  end)

  let dedup t =
    SM.map
      (fun host_plan ->
        let _seen, tasks =
          List.fold_left host_plan.tasks ~init:(Tasks.empty, [])
            ~f:(fun (seen, tasks) task ->
              if Tasks.mem task seen then (seen, tasks)
              else (Tasks.add task seen, task :: tasks))
        in
        { host_plan with tasks = List.rev tasks })
      t
end

(** This is what we get back from lib/admin-ssh.py after executing the plan. *)
module Ssh_output = struct
  open Melange_json.Primitives

  type cmd_output = Command.output [@@deriving of_json]
  type upload_status = [ `Done | `Error ]

  let upload_status_of_json =
   fun x ->
    match x with
    | `String "done" -> `Done
    | `String "error" -> `Error
    | json ->
        Melange_json.of_json_error ~json
          "expected upload status to be 'done' or 'error'"

  type upload_output = {
    remote : string;
    status : upload_status;
    error : string option;
  }
  [@@deriving of_json] [@@ocaml.warning "-69"]

  type commands = Command.output SM.t [@@deriving of_json]
  (** command output by command string *)

  type uploads = upload_output list [@@deriving of_json]
  (** upload outputs *)

  type host_output = { commands : commands; uploads : uploads }
  [@@deriving of_json]
  (** output for a single host *)

  type t = host_output SM.t [@@deriving of_json]
  (** host output by hostname *)

  let is_ok t =
    SM.fold
      (fun _host out acc ->
        acc
        &&
        let ok_commands =
          SM.fold
            (fun _cmd out acc -> out.Command.exit_code = 0 && acc)
            out.commands true
        in
        let ok_uploads =
          List.for_all out.uploads ~f:(fun up ->
              match up.status with `Done -> true | `Error -> false)
        in
        ok_commands && ok_uploads)
      t true
end

(** API *)

(** Effects. *)

type 'a keyinfo = { merge : 'a -> 'a -> 'a; default : 'a }

module Effs = struct
  include Hmap.Make (struct
    type 'a t = 'a keyinfo
  end)

  let add k v effs =
    match find k effs with
    | None -> add k v effs
    | Some v' ->
        let { merge; default = _ } = Key.info k in
        let v = merge v' v in
        add k v effs

  let get k effs =
    match find k effs with
    | Some v -> v
    | None ->
        let { merge = _; default } = Key.info k in
        default
end

type 'a eff = 'a Effs.key
(** Operations, can produce effects which we later can handle. *)

let define_list () : 'a list eff =
  Effs.Key.create { merge = List.append; default = [] }

let define_flag () : bool eff =
  Effs.Key.create { merge = (fun x y -> x || y); default = false }

type _ Effect.t +=
  | Get_eff : 'a eff -> 'a Effect.t
        (** Get a value associated with an effect in the current context. *)

(** Query is a way to execute commands and get typed results back. *)
module Query : sig
  type 'a t

  val cmd : ?use_sudo:bool -> ?desc:string -> string -> Command.output t
  (** Execute a command and get its output as a list of lines. *)

  val cmdf :
    ?use_sudo:bool ->
    ?desc:string ->
    ('a, unit, string, Command.output t) format4 ->
    'a

  val return : 'a -> 'a t
  (** Return a value without executing any command. *)

  val ( let+ ) : 'a t -> ('a -> 'b) -> 'b t
  (** Map the result of a query. *)

  val ( and+ ) : 'a t -> 'b t -> ('a * 'b) t
  (** Combine two queries into one that returns a pair of results. *)

  val get_eff : 'a eff -> 'a t
  (** Query a value associated with an effect in the current context. *)

  val all_cmds : 'a t -> Command.t list
  (** Get all commands involved in the query. *)

  val eval : Ssh_output.commands -> 'a t -> 'a
  (** Evaluate the query given the SSH output. *)
end = struct
  type _ t =
    | Q_cmd : Command.t -> Command.output t
    | Q_both : 'a t * 'b t -> ('a * 'b) t
    | Q_map : 'a t * ('a -> 'b) -> 'b t
    | Q_return : 'a -> 'a t
    | Q_get_eff : 'a eff -> 'a t

  let ( let+ ) q f = Q_map (q, f)
  let ( and+ ) x y = Q_both (x, y)
  let get_eff eff = Q_get_eff eff
  let return x = Q_return x
  let cmd ?use_sudo ?desc cmd = Q_cmd (Command.cmd ?use_sudo ?desc cmd)
  let cmdf ?use_sudo ?desc fmt = ksprintf (cmd ?use_sudo ?desc) fmt

  let rec all_cmds : type a. a t -> Command.t list -> Command.t list =
   fun cmd acc ->
    match cmd with
    | Q_cmd c -> c :: acc
    | Q_both (q1, q2) -> all_cmds q1 (all_cmds q2 acc)
    | Q_map (q, _) -> all_cmds q acc
    | Q_return _ -> []
    | Q_get_eff _ -> []

  let all_cmds cmd = all_cmds cmd []

  let rec eval : type a. Ssh_output.commands -> a t -> a =
   fun commands query ->
    match query with
    | Q_cmd c -> (
        match SM.find_opt c.Command.command commands with
        | Some output -> output
        | None ->
            failwith (spf "command output not found: %s" c.Command.command))
    | Q_both (q1, q2) ->
        let v1 = eval commands q1 in
        let v2 = eval commands q2 in
        (v1, v2)
    | Q_map (q, f) ->
        let v = eval commands q in
        f v
    | Q_return x -> x
    | Q_get_eff eff -> Effect.perform (Get_eff eff)
end

(** Op represents an operation to be performed on a target, first it queries
    target. *)
module Op = struct
  type t =
    | Op : {
        query : 'a Query.t;
        apply : 'a -> unit;
        effs : Effs.t; (* effects this op produces when executed *)
      }
        -> t

  type _ Effect.t +=
    | Ssh_plan_task : Ssh_plan.task -> unit Effect.t
          (** An operation registers tasks to be performed via this effect. *)

  let exec ?(use_sudo = false) ?desc cmd =
    let cmd = Command.cmd ~use_sudo ?desc cmd in
    Effect.perform (Ssh_plan_task (Ssh_plan.Command cmd))

  let execf ?use_sudo ?desc fmt = ksprintf (exec ?use_sudo ?desc) fmt

  let cp ?(use_sudo = false) ?chmod ?chown ~remote local =
    let upload = { Ssh_plan.local; remote; use_sudo; chmod; chown } in
    let upload = Ssh_plan.Upload upload in
    Effect.perform (Ssh_plan_task upload)

  let cp_content ?(use_sudo = false) ?chmod ?chown ~remote content =
    let upload = { Ssh_plan.content; remote; use_sudo; chmod; chown } in
    let upload = Ssh_plan.Upload_content upload in
    Effect.perform (Ssh_plan_task upload)

  let ( let+ ) query apply = Op { query; apply; effs = Effs.empty }
  let ( and+ ) = Query.( and+ )
  let annotate eff v (Op op) = Op { op with effs = Effs.add eff v op.effs }
  let annotate_many eff v ops = List.map ops ~f:(annotate eff v)
end

(** Target represents a remote machine. *)
module Target : sig
  type t

  val make : ?use_sudo:bool -> string -> t
  (** Create a target given its hostname. *)

  val hostname : t -> string
  (** Get the hostname of the target. *)

  val perform : t -> Op.t -> unit
  (** Register an operation to be performed on the target. *)

  val perform_many : t -> Op.t list -> unit
  (** Register an operation to be performed on the target. *)

  val query_plan : t -> string * Ssh_plan.host_plan
  (** Get the query plan for the target. *)

  val apply_plan :
    t -> Ssh_output.commands -> (string * Ssh_plan.host_plan) option
  (** Given the SSH output after executing the query plan, get the apply plan.
  *)
end = struct
  type t = {
    hostname : string;
    use_sudo : bool;
    mutable rev_ops : Op.t list;
    mutable effs : Effs.t;
  }

  let make ?(use_sudo = false) hostname =
    { hostname; rev_ops = []; effs = Effs.empty; use_sudo }

  let hostname t = t.hostname
  let perform t op = t.rev_ops <- op :: t.rev_ops
  let perform_many t ops = List.iter ops ~f:(perform t)

  let cmd_with_sudo t (cmd : Ssh_plan.command) =
    { cmd with Command.use_sudo = cmd.use_sudo || t.use_sudo }

  let with_sudo t = function
    | Ssh_plan.Command cmd ->
        Ssh_plan.Command
          { cmd with Command.use_sudo = cmd.use_sudo || t.use_sudo }
    | Ssh_plan.Upload up ->
        Ssh_plan.Upload { up with use_sudo = up.use_sudo || t.use_sudo }
    | Ssh_plan.Upload_content up ->
        Ssh_plan.Upload_content { up with use_sudo = up.use_sudo || t.use_sudo }

  let query_plan t =
    let tasks =
      List.flatten
        (List.rev_map t.rev_ops
           ~f:(fun (Op.Op { query; apply = _; effs = _ }) ->
             let cmds = Query.all_cmds query in
             List.map cmds ~f:(fun cmd ->
                 Ssh_plan.Command (cmd_with_sudo t cmd))))
    in
    (t.hostname, { Ssh_plan.tasks; username = None })

  let apply_plan t ssh_output =
    let tasks =
      List.map (List.rev t.rev_ops) ~f:(fun (Op.Op { query; apply; effs }) ->
          let tasks = ref [] in
          let () =
            try
              let result = Query.eval ssh_output query in
              apply result
            with
            | effect Op.Ssh_plan_task task, k ->
                tasks := with_sudo t task :: !tasks;
                Effect.Deep.continue k ()
            | effect Get_eff eff, k ->
                let has = Effs.get eff t.effs in
                Effect.Deep.continue k has
          in
          let () =
            match (!tasks, Effs.is_empty effs) with
            | [], _ | _, true -> ()
            | _ ->
                t.effs <-
                  Effs.fold (fun (Effs.B (k, v)) -> Effs.add k v) effs t.effs
          in
          List.rev !tasks)
      |> List.flatten
    in
    match tasks with
    | [] -> None
    | tasks -> Some (t.hostname, { Ssh_plan.tasks; username = None })
end

module Std = struct
  (** Utils *)

  let errorf fmt =
    ksprintf
      (fun s ->
        prerr_endline s;
        exit 1)
      fmt

  let assume_exited_0 status =
    match status with Unix.WEXITED 0 -> () | _ -> errorf "sha256sum: error"

  let read_sha256 line =
    match line with
    | Some l -> String.sub l ~pos:0 ~len:64
    | None -> errorf "sha256sum: no output"

  let sha256_of_string content =
    let ic, oc = Unix.open_process "sha256sum" in
    Out_channel.output_string oc content;
    Out_channel.close oc;
    let line = In_channel.input_line ic in
    assume_exited_0 (Unix.close_process (ic, oc));
    read_sha256 line

  let sha256_of_file path =
    let ic = Unix.open_process_in (sprintf "sha256sum %s" path) in
    let line = In_channel.input_line ic in
    assume_exited_0 (Unix.close_process_in ic);
    read_sha256 line

  (** Effects. *)

  let requires_systemd_daemon_reload : bool eff = define_flag ()
  let requires_systemd_reload_or_restart : string list eff = define_list ()

  (** Queries *)

  let single_stdout_line (out : Command.output) =
    match out.stdout with
    | [ line ] -> String.trim line
    | _ -> Command.failf out "expected single line of stdout"

  let single_stdout_line_res (out : Command.output) =
    match out.stdout with
    | [ line ] -> Ok (String.trim line)
    | _ -> Error "expected single line of stdout"

  type file_info = { chmod : string; chown : string; sha256sum : string }

  let file_info filename =
    Query.(
      let+ out =
        cmdf
          ~desc:(spf "file_info %s" filename)
          "stat -c '%%F\t%%U:%%G\t%%a' %s && sha256sum %s | cut -d' ' -f1"
          filename filename
      in
      if out.exit_code <> 0 then None
      else
        match out.stdout with
        | [ stat; sha256sum ] -> (
            match String.split_on_char ~by:'\t' stat with
            | [ "regular file"; chown; chmod ] ->
                Some { chmod; chown; sha256sum }
            | [ _; _; _ ] -> None
            | _ -> Command.failf out "file_info %s: unexpected output" filename)
        | _ -> Command.failf out "file_info %s: unexpected output" filename)

  type dir_info = { chmod : string; chown : string }

  let dir_info path =
    let open Query in
    let+ stat =
      cmdf
        ~desc:(sprintf "dir_info %s" path)
        "stat -c '%%F\t%%U:%%G\t%%a' %s" path
    in
    if stat.exit_code <> 0 then None
    else
      match single_stdout_line stat |> String.split_on_char ~by:'\t' with
      | [ "directory"; chown; chmod ] -> Some { chmod; chown }
      | [ _; _; _ ] -> None
      | _ -> Command.failf stat "unexpected stat output for dir %s" path

  let package_installed pkg =
    Query.(
      let+ out =
        cmdf
          ~desc:(spf "package_installed %s" pkg)
          "dpkg-query -W -f='${db:Status-Abbrev}' %s" pkg
      in
      if out.exit_code <> 0 then false
      else match single_stdout_line out with "ii" -> true | _ -> false)

  (** Systemd unit enablement states as returned by [systemctl is-enabled]. *)
  type unit_enable_state =
    | Enabled  (** enabled or enabled-runtime *)
    | Disabled  (** disabled - has [Install] section but not enabled *)
    | Static  (** static - no [Install] section, may start as dependency *)
    | Indirect  (** indirect/alias - enabled via Also= or symlink *)
    | Masked  (** masked - blocked from starting *)
    | Not_found  (** unit does not exist *)
    | Other of string  (** linked, generated, transient, bad, etc. *)

  (** Query the enablement state of a systemd unit. Uses [systemctl is-enabled]
      to determine if the unit will start at boot. *)
  let systemd_unit_enable_state unit_name =
    Query.(
      let+ out =
        cmdf
          ~desc:(spf "systemd_unit_enable_state %s" unit_name)
          "systemctl is-enabled -- %s" unit_name
      in
      let parse_state s =
        match String.trim s with
        | "enabled" | "enabled-runtime" -> Enabled
        | "disabled" -> Disabled
        | "static" -> Static
        | "indirect" | "alias" -> Indirect
        | "masked" | "masked-runtime" -> Masked
        | "not-found" -> Not_found
        | s -> Other s
      in
      match out.stdout with
      | [ line ] -> parse_state line
      | [] when out.exit_code = 4 -> Not_found
      | [] ->
          Command.failf out "empty output for systemctl is-enabled %s" unit_name
      | _ ->
          Command.failf out "multi-line output for systemctl is-enabled %s"
            unit_name)

  (** Check if a systemd unit is enabled (will start at boot). Returns [true]
      only for [Enabled] state (enabled or enabled-runtime). *)
  let systemd_unit_enabled unit_name =
    Query.(
      let+ state = systemd_unit_enable_state unit_name in
      match state with Enabled -> true | _ -> false)

  (** Check if a systemd unit exists (is known to systemd). Returns [false] only
      for [Not_found] state. *)
  let systemd_unit_exists unit_name =
    Query.(
      let+ state = systemd_unit_enable_state unit_name in
      match state with Not_found -> false | _ -> true)

  (** Systemd unit active states as returned by [systemctl is-active]. *)
  type unit_active_state =
    | Active  (** active, reloading, refreshing - unit is running *)
    | Inactive  (** inactive - unit is stopped *)
    | Failed  (** failed - unit crashed or errored *)
    | Activating  (** activating - unit is starting *)
    | Deactivating  (** deactivating - unit is stopping *)
    | Other of string  (** maintenance, unknown, etc. *)

  (** Query the active state of a systemd unit. Uses [systemctl is-active] to
      determine if the unit is currently running. *)
  let systemd_unit_active_state unit_name =
    Query.(
      let+ out =
        cmdf
          ~desc:(spf "systemd_unit_active_state %s" unit_name)
          "systemctl is-active -- %s" unit_name
      in
      match out.stdout with
      | [ line ] -> (
          match String.trim line with
          | "active" | "reloading" | "refreshing" -> Active
          | "inactive" -> Inactive
          | "failed" -> Failed
          | "activating" -> Activating
          | "deactivating" -> Deactivating
          | s -> Other s)
      | [] -> Other "unknown"
      | _ ->
          Command.failf out "multi-line output for systemctl is-active %s"
            unit_name)

  (** Check if a systemd unit is currently running. Returns [true] for [Active]
      state (active, reloading, refreshing). *)
  let systemd_unit_running unit_name =
    Query.(
      let+ state = systemd_unit_active_state unit_name in
      match state with Active -> true | _ -> false)

  (** Check if a systemd unit is in failed state. *)
  let systemd_unit_failed unit_name =
    Query.(
      let+ state = systemd_unit_active_state unit_name in
      match state with Failed -> true | _ -> false)

  (** Operations *)

  open Op

  let file ?(chmod = "644") ?chown ~remote path =
    let+ file_info = file_info remote in
    match file_info with
    | None -> Op.cp ~chmod ?chown ~remote path
    | Some info ->
        let sha256 = sha256_of_file path in
        if not Equal.(string sha256 info.sha256sum) then
          Op.cp ~chmod ?chown ~remote path
        else begin
          Option.iter
            (fun chown ->
              if not Equal.(string info.chown chown) then
                Op.execf "chown -R %s %s" chown remote)
            chown;
          if not Equal.(string info.chmod chmod) then
            Op.execf "chmod %s %s" chmod remote
        end

  let file_content ?chmod ?chown ~remote content =
    let open Op in
    let+ info = file_info remote in
    let sha256 = sha256_of_string content in
    let need_update =
      match info with
      | None -> true
      | Some info -> not (String.equal info.sha256sum sha256)
    in
    let need_update =
      need_update
      ||
      match (chown, info) with
      | None, _ -> false
      | Some _, None -> true
      | Some chown, Some info -> not (String.equal chown info.chown)
    in
    let need_update =
      need_update
      ||
      match (chmod, info) with
      | None, _ -> false
      | Some _, None -> true
      | Some chmod, Some info -> not (String.equal chmod info.chmod)
    in
    if need_update then Op.cp_content ?chmod ?chown ~remote content

  let dir ?chmod ?chown dir =
    let open Op in
    let+ info = dir_info dir in
    let with_chmod cmd =
      match (chmod, info) with
      | Some chmod, Some info ->
          if not (String.equal chmod info.chmod) then
            sprintf "chmod %s %s" chmod dir :: cmd
          else cmd
      | Some chmod, None -> sprintf "chmod %s %s" chmod dir :: cmd
      | None, _ -> cmd
    in
    let with_chown cmd =
      match (chown, info) with
      | Some chown, Some info ->
          if not (String.equal chown info.chown) then
            sprintf "chown %s %s" chown dir :: cmd
          else cmd
      | Some chown, None -> sprintf "chown %s %s" chown dir :: cmd
      | None, _ -> cmd
    in
    let exec cmd =
      match cmd with
      | [] -> ()
      | cmd ->
          let cmd = String.concat ~sep:" && " (List.rev cmd) in
          Op.exec ~desc:(sprintf "dir %s" dir) cmd
    in
    let cmd =
      match info with None -> [ sprintf "mkdir -p %s" dir ] | Some _ -> []
    in
    exec (cmd |> with_chmod |> with_chown)

  let package ~pkg =
    let+ package_installed = package_installed pkg in
    if not package_installed then Op.exec (spf "apt-get install -y %S" pkg)

  let systemd_daemon_reload () =
    let+ should_reload = Query.get_eff requires_systemd_daemon_reload in
    if should_reload then Op.exec "systemctl daemon-reload"

  let systemd_reload_or_restart_all () =
    let+ units = Query.get_eff requires_systemd_reload_or_restart in
    List.iter units ~f:(fun unit ->
        Op.execf "systemctl reload-or-restart %s" unit)

  let systemd_reload_or_restart unit =
    let+ units = Query.get_eff requires_systemd_reload_or_restart in
    if List.mem ~eq:String.equal unit units then
      Op.execf "systemctl reload-or-restart %s" unit

  let systemd_try_reload_or_restart_all () =
    let+ units = Query.get_eff requires_systemd_reload_or_restart in
    List.iter units ~f:(fun unit ->
        Op.execf "systemctl try-reload-or-restart %s" unit)

  let systemd_try_reload_or_restart unit =
    let+ units = Query.get_eff requires_systemd_reload_or_restart in
    if List.mem ~eq:String.equal unit units then
      Op.execf "systemctl try-reload-or-restart %s" unit

  let systemd_enable ?(now = false) unit =
    let+ enable_state = systemd_unit_enable_state unit
    and+ active_state = systemd_unit_active_state unit in
    let needs_enable =
      match enable_state with
      | Enabled | Indirect -> false
      | Disabled | Static | Masked | Not_found | Other _ -> true
    in
    let needs_start =
      now
      &&
      match active_state with
      | Active -> false
      | Inactive | Failed | Activating | Deactivating | Other _ -> true
    in
    match (needs_enable, needs_start) with
    | true, true -> Op.execf "systemctl enable --now -- %s" unit
    | true, false -> Op.execf "systemctl enable -- %s" unit
    | false, true -> Op.execf "systemctl start -- %s" unit
    | false, false -> ()

  let systemd_disable ?(now = false) unit =
    let+ enable_state = systemd_unit_enable_state unit
    and+ active_state = systemd_unit_active_state unit in
    let needs_disable =
      match enable_state with
      | Disabled | Static | Masked | Not_found -> false
      | Enabled | Indirect | Other _ -> true
    in
    let needs_stop =
      now
      &&
      match active_state with
      | Inactive | Failed -> false
      | Active | Activating | Deactivating | Other _ -> true
    in
    match (needs_disable, needs_stop) with
    | true, true -> Op.execf "systemctl disable --now -- %s" unit
    | true, false -> Op.execf "systemctl disable -- %s" unit
    | false, true -> Op.execf "systemctl stop -- %s" unit
    | false, false -> ()

  let systemd_start unit =
    let+ state = systemd_unit_active_state unit in
    match state with
    | Active -> () (* already running *)
    | Inactive | Failed | Activating | Deactivating | Other _ ->
        Op.execf "systemctl start -- %s" unit
end

open struct
  let targets : Target.t list ref = ref []
end

let target ?use_sudo hostname =
  let t = Target.make ?use_sudo hostname in
  targets := t :: !targets;
  t

module Cli = struct
  open! Cmdliner

  (** Execute an SSH plan and return the raw output. *)
  let execute_ssh_plan ~par ~par_per_host ?(serial = false) (plan : Ssh_plan.t)
      : string =
    let json = Ssh_plan.to_json plan in
    let json = Melange_json.to_string json in

    let tmp_file, oc = Filename.open_temp_file "admin" ".json" in
    output_string oc json;
    close_out oc;

    let opts =
      [ spf "--par=%d" par; spf "--par-per-host=%d" par_per_host ]
      @ if serial then [ "--serial" ] else []
    in
    let cmd =
      spf "admin-ssh.py %s < %s" (String.concat ~sep:" " opts) tmp_file
    in
    let ic = Unix.open_process_in cmd in
    let out = In_channel.input_all ic in
    let exit_code = Unix.close_process_in ic in

    Sys.remove tmp_file;

    (match exit_code with
    | Unix.WEXITED 0 -> ()
    | _ -> failwith "admin-ssh.py execution failed");

    out

  let get_query_plan () =
    List.map !targets ~f:Target.query_plan |> SM.of_list |> Ssh_plan.dedup

  (** Execute the query plan via SSH and return raw output and parsed output. *)
  let execute_query_plan ~par ~par_per_host () : string * Ssh_output.t =
    prerr_endline "executing query plan...";
    let plan = get_query_plan () in
    let out = execute_ssh_plan ~par ~par_per_host plan in
    (out, Ssh_output.of_json (Yojson.Basic.from_string out))

  let get_apply_plan query_out =
    List.filter_map !targets ~f:(fun t ->
        let hostname = Target.hostname t in
        match SM.find_opt hostname query_out with
        | Some host_output ->
            Target.apply_plan t host_output.Ssh_output.commands
        | None -> failwith (spf "No SSH output found for hostname: %s" hostname))
    |> SM.of_list |> Ssh_plan.dedup

  let par =
    Arg.(
      value & opt int 10
      & info [ "par" ] ~docv:"N"
          ~doc:"Number of parallel SSH connections to different hosts")

  let par_per_host =
    Arg.(
      value & opt int 4
      & info [ "par-per-host" ] ~docv:"N"
          ~doc:"Number of parallel command executions per host")

  (** Output query plan as JSON on stdout. *)
  let query_plan_cmd : unit Cmdliner.Cmd.t =
    let doc = "Output query plan as JSON on stdout" in
    let run () =
      let plan = get_query_plan () in
      let json = Ssh_plan.to_json plan in
      print_endline (Melange_json.to_string json)
    in
    Cmd.v (Cmd.info "query-plan" ~doc) Term.(const run $ const ())

  (** Execute query plan and print outputs on stdout. *)
  let query_cmd : unit Cmdliner.Cmd.t =
    let doc = "Execute query plan and print outputs" in
    let run par par_per_host () =
      let out, _ssh_output = execute_query_plan ~par ~par_per_host () in
      print_endline out
    in
    Cmd.v (Cmd.info "query" ~doc)
      Term.(const run $ par $ par_per_host $ const ())

  (** Execute query plan and then output apply plan as JSON on stdout. *)
  let apply_plan_cmd : unit Cmdliner.Cmd.t =
    let doc = "Output apply plan as JSON on stdout" in
    let run par par_per_host () =
      let _out, ssh_output = execute_query_plan ~par ~par_per_host () in
      let apply_plan = get_apply_plan ssh_output in
      let apply_plan = Ssh_plan.to_json apply_plan in
      print_endline (Melange_json.to_string apply_plan)
    in
    Cmd.v
      (Cmd.info "apply-plan" ~doc)
      Term.(const run $ par $ par_per_host $ const ())

  (** Execute query plan and then apply changes. *)
  let apply_cmd : unit Cmdliner.Cmd.t =
    let doc = "Execute apply plan" in
    let run par par_per_host () =
      let _, query_out = execute_query_plan ~par ~par_per_host () in
      let apply_plan = get_apply_plan query_out in
      if SM.is_empty apply_plan then prerr_endline "nothing to apply..."
      else begin
        prerr_endline "executing apply plan...";
        let out = execute_ssh_plan ~par ~par_per_host ~serial:true apply_plan in
        let out = Melange_json.of_string out in
        let out = Ssh_output.of_json out in
        if not (Ssh_output.is_ok out) then exit 1
      end
    in
    Cmd.v (Cmd.info "apply" ~doc)
      Term.(const run $ par $ par_per_host $ const ())
end

let main () =
  let () = Printexc.record_backtrace true in
  let open Cmdliner in
  let doc = "Remote administration tool" in
  let main_cmd =
    Cmd.group (Cmd.info "admin" ~doc)
      Cli.[ query_plan_cmd; query_cmd; apply_plan_cmd; apply_cmd ]
  in
  exit (Cmd.eval main_cmd)
