##@ Help-related tasks
.PHONY: help
help: ## Help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^(\s|[a-zA-Z_0-9-])+:.*?##/ { printf "  \033[36m%-35s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ IIB-related tasks
.PHONY: iib
iib: ## Call IIB playbook
	ansible-playbook iib.yml

.PHONY: lookup
lookup: ## Looks up IIB
	go run main.go

##@ Test and Linters Tasks

.PHONY: ansible-lint
ansible-lint: ## run ansible lint on ansible/ folder
	ansible-lint -vvv *.yml
