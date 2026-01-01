.PHONY: fmt build
fmt:
	uvx ruff format ./lib/admin-ssh.py
	dune fmt
build:
	dune build
