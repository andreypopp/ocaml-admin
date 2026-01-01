# admin

Remote administration tool in OCaml. Define facts about machines, query state via SSH, apply changes.

## Example: Install and Run Caddy

Create a `provision.ml`:
```ocaml
#!/usr/bin/env ocaml

#use "topfind";;
#require "admin";;

open Admin

let () =
  let server = target ~use_sudo:true "myserver.example.com" in
  let () =
    Target.perform_many server [
      Std.package ~pkg:"caddy";
      Std.file_content ~remote:"/etc/caddy/Caddyfile" {| :80 { respond "Hello from Caddy!" } |};
      Std.systemd_enable ~now:true "caddy";
    ]
  in
  main ()
```

Then:
```bash
chmod +x provision.ml
./provision.ml apply-plan | jq         # preview changes
./provision.ml apply                   # apply changes
```
