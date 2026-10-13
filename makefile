# makefile
.PHONY: all help install uninstall FORCE

TOOLS_SRC := $(wildcard src/tools/*.cr)
TOOLS_BIN := $(patsubst src/tools/%.cr,~/.local/bin/%,$(TOOLS_SRC))
SKILL     := ~/.agents/skills/dev/SKILL.md

all: help

help:               ## Show this help text
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  make %-18s %s\n", $$1, $$2}'

install: $(TOOLS_BIN) $(SKILL) ## Builds and installs all tools and the dev skill

~/.local/bin/%: src/tools/%.cr FORCE
	@mkdir -p ~/.local/bin
	crystal build --release --no-debug $< -o $@

$(SKILL): SKILL.md FORCE
	@mkdir -p $(dir $(SKILL))
	cp SKILL.md $(SKILL)

uninstall:          ## Removes all installed tools
	rm -f $(TOOLS_BIN) ~/.local/bin/project ~/.local/bin/tok ~/.local/bin/loc ~/.local/bin/chlog