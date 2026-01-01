# CLAUDE.md

## Project Overview

This is a remote administration tool written in OCaml. It allows defining facts
about remote machines (targets) by executing commands (queries) and then
applying changes (operations) to realize those facts. All remote execution is
performed over SSH using the `lib/admin-ssh.py` helper script.

## Build & Run

```bash
make build                               # Build the project
dune exec ./example/main.exe             # Run the example main binary
dune exec ./example/main.exe --help      # Show CLI help
dune exec ./example/main.exe query-plan  # Output query plan as JSON
dune exec ./example/main.exe query       # Execute query plan via SSH
dune exec ./example/main.exe apply-plan  # Output apply plan as JSON
dune exec ./example/main.exe apply       # Execute apply plan
```

## Project Structure

```
admin/
├── lib/
│   ├── admin.ml      # Main library - all core modules
│   ├── admin.mli     # Library interface
│   ├── dune          # Library build config
│   └── admin-ssh.py  # Python SSH executor (parallel-ssh based)
├── example/
│   ├── main.ml       # Example usage / entry point
│   └── dune          # Executable build config
└── test/
    └── test_admin.ml # Tests
```

## Key Modules (lib/admin.ml)

### `Command`
Command representation with description and sudo flag.
- `type t = { command: string; desc: string option; use_sudo: bool }`
- `type output = { stdout: string list; stderr: string list; exit_code: int }`

### `Query`
Applicative functor for composing commands that return typed results.
- `cmd ?use_sudo ?desc string -> Command.output t` - Create a command query
- `cmdf ?use_sudo ?desc format -> ... -> Command.output t` - Printf-style command
- `return : 'a -> 'a t` - Pure value
- `get_eff : 'a eff -> 'a t` - Read an effect value from the current context
- `let+` / `and+` - Applicative syntax for combining queries
- `eval : Ssh_output.commands -> 'a t -> 'a` - Evaluate query given SSH output

### `Op`
Operations combine a query with an apply function.
- `type t = Op : { query: 'a Query.t; apply: 'a -> unit; effs: Effs.t } -> t`
- Module-level functions (called within apply):
  - `exec : ?use_sudo:bool -> ?desc:string -> string -> unit` - Execute a command
  - `execf : ?use_sudo:bool -> ?desc:string -> format -> ... -> unit` - Printf-style exec
  - `cp : ?use_sudo:bool -> ?chmod:string -> ?chown:string -> remote:string -> string -> unit` - Copy a file
  - `cp_content : ?use_sudo:bool -> ?chmod:string -> ?chown:string -> remote:string -> string -> unit` - Copy content as a file
- `let+` / `and+` - Define operations from queries
- `annotate : 'a eff -> 'a -> t -> t` - Annotate an operation with an effect
- `annotate_many : 'a eff -> 'a -> t list -> t list` - Annotate multiple operations

### `Target`
Represents a remote machine.
- `make ?use_sudo hostname -> t` - Create a target
- `perform : t -> Op.t -> unit` - Register an operation on target
- `perform_many : t -> Op.t list -> unit` - Register multiple operations
- `query_plan : t -> string * Ssh_plan.host_plan` - Get query plan
- `apply_plan : t -> Ssh_output.commands -> (string * Ssh_plan.host_plan) option` - Get apply plan

### `Ssh_plan` / `Ssh_output`
JSON serialization for communication with `lib/admin-ssh.py`.

### `Cli`
Cmdliner-based CLI commands:
- `query-plan` - Output query plan as JSON
- `query` - Execute query plan and print outputs
- `apply-plan` - Execute query plan, then output apply plan as JSON
- `apply` - Execute query plan, then execute apply plan

## Adding New Queries

Queries are used to gather information from remote hosts. They are defined
using the `Query` module's applicative interface.

### Basic Pattern

```ocaml
let my_query arg =
  Query.(
    let+ out = cmdf ~desc:"description" "command %s" arg in
    (* parse out.stdout, out.stderr, out.exit_code and return typed result *)
    ...)
```

### Query API

- `Query.cmd ?use_sudo ?desc string -> Command.output t` - Execute a shell command
- `Query.cmdf ?use_sudo ?desc format -> ... -> Command.output t` - Printf-style command
- `Query.return : 'a -> 'a t` - Return a pure value without executing anything
- `Query.get_eff : 'a eff -> 'a t` - Read an effect value from the current context
- `let+` - Map over query result: `let+ result = query in transform result`
- `and+` - Combine queries: `let+ a = query1 and+ b = query2 in (a, b)`

### Command Output

`Command.output` contains:
- `stdout : string list` - Lines of stdout
- `stderr : string list` - Lines of stderr
- `exit_code : int` - Exit code (0 = success)

Helper functions in `Std`:
- `single_stdout_line : Command.output -> string` - Extract single line (fails if not exactly one)
- `single_stdout_line_res : Command.output -> (string, string) result` - Same but returns Result

### Examples

**Simple boolean query:**
```ocaml
let package_installed pkg =
  Query.(
    let+ out = cmdf ~desc:(spf "package_installed %s" pkg)
        "dpkg-query -W -f='${db:Status-Abbrev}' %s" pkg
    in
    match single_stdout_line out with "ii" -> true | _ -> false)
```

More examples in lib/admin.ml, module `Std`.

### Exporting Queries

When adding new queries to `Std`, also add their signatures to `lib/admin.mli`
in the `Std` module section. This exposes them to library users.

### Using Queries in Operations

Queries are used within `Op.t` definitions to determine what changes need to be
applied. The `Op.let+` operator takes a query and a function that receives the
query result and performs operations:

```ocaml
let my_operation value =
  let open Op in
  let+ current_state = my_query in
  if current_state <> value then
    Op.execf "command to update %s" value
```

Operations are registered on targets using `Target.perform` or `Target.perform_many`:

```ocaml
let () =
  Target.perform_many my_target [
    my_operation "desired_value";
    Std.package ~pkg:"nginx";
  ]
```

## SSH Protocol (lib/admin-ssh.py)

Input JSON (stdin):
```json
{
  "<hostname>": {
    "username": "<string|null>",
    "tasks": [
      {"type": "command", "command": "<cmd>", "desc": "<string|null>", "use_sudo": <bool>},
      {"type": "upload", "local": "<path>", "remote": "<path>", "use_sudo": <bool>, "chmod": "<mode|null>", "chown": "<user:group|null>"},
      {"type": "upload-content", "content": "<string>", "remote": "<path>", "use_sudo": <bool>, "chmod": "<mode|null>", "chown": "<user:group|null>"}
    ]
  }
}
```

Output JSON (stdout):
```json
{
  "<hostname>": {
    "commands": {
      "<cmd>": {"exit_code": <int>, "stdout": [<str>], "stderr": [<str>]}
    },
    "uploads": [
      {"remote": "<path>", "status": "done"|"error", "error": <string|null>}
    ]
  }
}
```

## Dependencies

- `cmdliner` - CLI parsing
- `melange-json-native` - JSON serialization (with PPX)
- `containers` - Standard library (opened as ContainersLabels)
- `hmap` - Heterogeneous maps for effects
- `unix` - Process execution
- Python (via `uv` inline script): `parallel-ssh`, `click`, `rich` (for admin-ssh.py)

## Naming Conventions

- The project uses `ContainersLabels` so list functions use labeled arguments: `List.map xs ~f:...`
- `spf` is an alias for `sprintf`
