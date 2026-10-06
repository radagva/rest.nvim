.PHONY: fmt lint test check smoke

fmt:
	stylua .

lint:
	luacheck .

test:
	busted

check: fmt lint test

smoke:
	nvim -l tests/smoke.lua
