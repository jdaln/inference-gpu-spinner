# Thin aliases over bin/spin. Pass extra args via ARGS, e.g.:
#   make up ARGS="--model qwen36 --plan GPU-12xCPU-240GB-1xH100"
.PHONY: help persistent-init up down status logs ssh plan fmt lint

help:            ; @bin/spin help
persistent-init: ; @bin/spin persistent-init
up:              ; @bin/spin up $(ARGS)
down:            ; @bin/spin down
status:          ; @bin/spin status
logs:            ; @bin/spin logs
ssh:             ; @bin/spin ssh $(ARGS)
plan:            ; @bin/spin plan

fmt:             ; tofu -chdir=terraform/persistent fmt && tofu -chdir=terraform/providers/upcloud fmt
lint:            ; ansible-lint
