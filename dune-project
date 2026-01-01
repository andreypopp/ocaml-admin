(lang dune 3.20)

(name admin)

(generate_opam_files true)

(source
 (github username/reponame))

(authors "Andrey Popp <me@andreypopp.com>")

(maintainers "Andrey Popp <me@andreypopp.com>")

(license LICENSE)

(package
 (name admin)
 (synopsis "Server administration DSL")
 (description "Server administration DSL")
 (depends ocaml cmdliner melange-json-native containers hmap))

; See the complete stanza docs at https://dune.readthedocs.io/en/stable/reference/dune-project/index.html
