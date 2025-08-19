submodule-init:
	git submodule update --init --recursive

submodule-pull:
	git pull --recurse-submodules
	git submodule update --init --recursive --remote --jobs 8

.PHONY: submodule-init submodule-pull