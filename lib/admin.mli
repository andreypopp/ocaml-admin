module Command : sig
  type t
  (** A command. *)

  type output = { stdout : string list; stderr : string list; exit_code : int }
  (** A command's output. *)

  val failf : output -> ('a, unit, string, 'b) format4 -> 'a
  (** Fail with a formatted error message including command output. *)

  val to_result : output -> string -> (output, string) result
  (** Convert command output to a result, returning [Ok output] if the exit code
      is zero, or [Error msg] otherwise, where [msg] is a formatted error
      message including command output. *)

  val to_resultf :
    output -> ('a, unit, string, (output, string) result) format4 -> 'a
  (** Like {!to_result} but with a formatted error message. *)
end

type 'a eff
(** Operations, can produce effects which we later can handle. *)

val define_list : unit -> 'a list eff
(** Define a new effect which collects a list of values. *)

val define_flag : unit -> bool eff
(** Define a new effect which is just a flag (present or not). *)

(** Query remote hosts. *)
module Query : sig
  type 'a t

  val cmd : ?use_sudo:bool -> ?desc:string -> string -> Command.output t

  val cmdf :
    ?use_sudo:bool ->
    ?desc:string ->
    ('a, unit, string, Command.output t) format4 ->
    'a

  val return : 'a -> 'a t
  val ( let+ ) : 'a t -> ('a -> 'b) -> 'b t
  val ( and+ ) : 'a t -> 'b t -> ('a * 'b) t

  val get_eff : 'a eff -> 'a t
  (** Query a value associated with an effect in the current context. *)
end

(** Operation is a query + mutable ops to perform to converge the target to the
    desired state. *)
module Op : sig
  type t

  val exec : ?use_sudo:bool -> ?desc:string -> string -> unit

  val execf :
    'a. ?use_sudo:bool -> ?desc:string -> ('a, unit, string, unit) format4 -> 'a

  val cp :
    ?use_sudo:bool ->
    ?chmod:string ->
    ?chown:string ->
    remote:string ->
    string ->
    unit

  val cp_content :
    ?use_sudo:bool ->
    ?chmod:string ->
    ?chown:string ->
    remote:string ->
    string ->
    unit

  val ( let+ ) : 'a Query.t -> ('a -> unit) -> t
  val ( and+ ) : 'a Query.t -> 'b Query.t -> ('a * 'b) Query.t

  val annotate : 'a eff -> 'a -> t -> t
  (** Annotate an operation with an effect. *)

  val annotate_many : 'a eff -> 'a -> t list -> t list
  (** Annotate many operations with an effect. *)
end

(** A target host. *)
module Target : sig
  type t

  val make : ?use_sudo:bool -> string -> t

  val perform : t -> Op.t -> unit
  (** Perform an operation on the target. *)

  val perform_many : t -> Op.t list -> unit
  (** Register an operation to be performed on the target. *)
end

(** Standard library of queries and operations. *)
module Std : sig
  (** Helpers. *)

  val single_stdout_line : Command.output -> string
  val single_stdout_line_res : Command.output -> (string, string) result

  (** Effects. *)

  val requires_systemd_daemon_reload : bool eff
  (** Effect indicating that a systemd daemon reload is needed. *)

  val requires_systemd_reload_or_restart : string list eff
  (** Effect indicating that a systemd service reload or restart is needed for
      the given services. *)

  (** Queries. *)

  type file_info = { chmod : string; chown : string; sha256sum : string }

  val file_info : string -> file_info option Query.t

  type dir_info = { chmod : string; chown : string }

  val dir_info : string -> dir_info option Query.t

  val package_installed : string -> bool Query.t
  (** Check if a package is installed. Supports apt. *)

  (** Systemd unit enablement states as returned by [systemctl is-enabled]. *)
  type unit_enable_state =
    | Enabled  (** enabled or enabled-runtime *)
    | Disabled  (** disabled - has [Install] section but not enabled *)
    | Static  (** static - no [Install] section, may start as dependency *)
    | Indirect  (** indirect/alias - enabled via Also= or symlink *)
    | Masked  (** masked - blocked from starting *)
    | Not_found  (** unit does not exist *)
    | Other of string  (** linked, generated, transient, bad, etc. *)

  val systemd_unit_enable_state : string -> unit_enable_state Query.t
  (** Query the enablement state of a systemd unit. *)

  val systemd_unit_enabled : string -> bool Query.t
  (** Check if a systemd unit is enabled (will start at boot). Returns [true]
      only for [Enabled] state. *)

  val systemd_unit_exists : string -> bool Query.t
  (** Check if a systemd unit exists (is known to systemd). Returns [false] only
      for [Not_found] state. *)

  (** Systemd unit active states as returned by [systemctl is-active]. *)
  type unit_active_state =
    | Active  (** active, reloading, refreshing - unit is running *)
    | Inactive  (** inactive - unit is stopped *)
    | Failed  (** failed - unit crashed or errored *)
    | Activating  (** activating - unit is starting *)
    | Deactivating  (** deactivating - unit is stopping *)
    | Other of string  (** maintenance, unknown, etc. *)

  val systemd_unit_active_state : string -> unit_active_state Query.t
  (** Query the active state of a systemd unit. *)

  val systemd_unit_running : string -> bool Query.t
  (** Check if a systemd unit is currently running. Returns [true] for [Active]
      state (active, reloading, refreshing). *)

  val systemd_unit_failed : string -> bool Query.t
  (** Check if a systemd unit is in failed state. *)

  (** Operations. *)

  val file : ?chmod:string -> ?chown:string -> remote:string -> string -> Op.t
  (** Put a file on the target. *)

  val file_content :
    ?chmod:string -> ?chown:string -> remote:string -> string -> Op.t
  (** Put a file on the target. *)

  val dir : ?chmod:string -> ?chown:string -> string -> Op.t
  (** Ensure a directory exists on the target. *)

  val package : pkg:string -> Op.t
  (** Install a package using the system's package manager. Supports apt. *)

  val systemd_daemon_reload : unit -> Op.t
  (** Do systemd daemon reload if needed. *)

  val systemd_reload_or_restart_all : unit -> Op.t
  (** Reload or restart all systemd units if needed. *)

  val systemd_reload_or_restart : string -> Op.t
  (** Reload or restart a systemd unit. *)

  val systemd_try_reload_or_restart_all : unit -> Op.t
  (** Reload or restart all systemd units if needed and running. *)

  val systemd_try_reload_or_restart : string -> Op.t
  (** Reload or restart a systemd unit if running. *)

  val systemd_enable : ?now:bool -> string -> Op.t
  (** Enable a systemd unit. Does nothing if already enabled or indirect. If
      [~now:true], also starts the unit if not already active. *)

  val systemd_disable : ?now:bool -> string -> Op.t
  (** Disable a systemd unit. Does nothing if already disabled, static, masked,
      or not found. If [~now:true], also stops the unit if active. *)

  val systemd_start : string -> Op.t
  (** Start a systemd unit. Does nothing if already active. *)
end

val target : ?use_sudo:bool -> string -> Target.t
(** Define a target host. *)

val main : unit -> unit
(** Main entry point. *)
