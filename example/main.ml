(** EXAMPLE CODE *)

open Printf
open Admin

let noted = target "noted.mechanize.systems" ~use_sudo:true

let oauth2_proxy_installed version =
  let open Query in
  let+ ok =
    cmdf
      ~desc:(sprintf "oauth2_proxy_installed %s" version)
      "oauth2-proxy --version | grep %s || echo nope" version
  in
  match Std.single_stdout_line ok with "nope" -> false | _ -> true

let oauth2_proxy ?(version = "7.13.0")
    ?(sha256 =
      "f6f8d5a6be3c48965eb3b98120316c179636b0428c09d267c8d5d6d2f9663feb") () =
  let open Op in
  let url =
    Printf.sprintf
      "https://github.com/oauth2-proxy/oauth2-proxy/releases/download/v%s/oauth2-proxy-v%s.linux-amd64.tar.gz"
      version version
  in
  let sha256_file = "/tmp/oauth2-proxy.sha256" in
  let+ installed = oauth2_proxy_installed version in
  if not installed then begin
    Op.exec
      ~desc:(sprintf "installing oauth2-proxy v%s" version)
      {%string|
      rm -rf /tmp/oauth2-proxy.tar.gz /tmp/oauth2-proxy.sha256 /tmp/oauth2-proxy-v%{version}.linux-amd64
      curl -fsSL '%{url}' -o /tmp/oauth2-proxy.tar.gz
      echo "%{sha256}  oauth2-proxy-v%{version}.linux-amd64/oauth2-proxy" > %{sha256_file}
      tar -xzf /tmp/oauth2-proxy.tar.gz -C /tmp;
      cd /tmp && sha256sum -c /tmp/oauth2-proxy.sha256;
      install -m 755 /tmp/oauth2-proxy-v%{version}.linux-amd64/oauth2-proxy /usr/local/bin/
      rm -rf /tmp/oauth2-proxy.tar.gz /tmp/oauth2-proxy.sha256 /tmp/oauth2-proxy-v%{version}.linux-amd64
      |}
  end

let () =
  let () =
    Target.configure
      ~effs:Effs.(empty |> add Std.requires_systemd_daemon_reload true)
      noted
      [
        Std.package ~pkg:"caddy";
        oauth2_proxy ();
        Std.file ~remote:"/etc/x" ~chown:"root:root" "./CLAUDE.md";
      ]
  in
  Target.configure noted
    [ Std.systemd_daemon_reload (); Std.systemd_enable ~now:true "caddy" ];
  main ()
