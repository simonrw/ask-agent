PLENARY_PATH ?= $(HOME)/.local/share/nvim/lazy/plenary.nvim
NVIM ?= nvim

.PHONY: test
test:
	env PATH="/opt/homebrew/bin:/usr/local/bin:$$PATH" \
		XDG_CACHE_HOME=/private/tmp XDG_STATE_HOME=/private/tmp XDG_DATA_HOME=/private/tmp \
		$(NVIM) --clean --headless \
		--cmd 'set rtp+=.' \
		--cmd 'set rtp+=$(PLENARY_PATH)' \
		-c 'runtime plugin/plenary.vim' \
		-c "PlenaryBustedDirectory tests { minimal_init = './setup.lua' }"
