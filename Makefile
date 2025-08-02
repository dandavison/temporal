submodule-update:
	git submodule update --init --recursive

submodule-add:
	bin/setup
	
.PHONY: clone