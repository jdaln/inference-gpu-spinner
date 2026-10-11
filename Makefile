# Thin aliases over bin/spin. Pass extra args via ARGS, e.g.:
#   make up ARGS="--model qwen36 --plan GPU-12xCPU-240GB-1xH100"
#   make down ARGS="--keep-disk"
# Every target that takes flags must pass $(ARGS): without it `make down ARGS=--keep-disk`
# silently dropped the flag and bin/spin deleted the weights disk by default.
.PHONY: help persistent-init up down status logs ssh plan fmt lint test

help:            ; @bin/spin help
persistent-init: ; @bin/spin persistent-init $(ARGS)
up:              ; @bin/spin up $(ARGS)
down:            ; @bin/spin down $(ARGS)
status:          ; @bin/spin status
logs:            ; @bin/spin logs
ssh:             ; @bin/spin ssh $(ARGS)
plan:            ; @bin/spin plan $(ARGS)

fmt:             ; tofu -chdir=terraform/persistent fmt && tofu -chdir=terraform/providers/upcloud fmt
lint:            ; ansible-lint
test:            ; @tests/run-offline-gates.sh $(ARGS)
