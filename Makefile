PREFIX ?= /usr/local

install:
	pip install .
	install -d $(HOME)/.claude/commands
	install -m 644 commands/td.md $(HOME)/.claude/commands/td.md
	install -d $(PREFIX)/bin
	install -m 755 hooks/pre-compact $(PREFIX)/bin/td-pre-compact

uninstall:
	pip uninstall -y td-cli
	rm -f $(PREFIX)/bin/td-pre-compact
	rm -f $(HOME)/.claude/commands/td.md

test:
	bash test_todo.sh
	python -m pytest tests/ -v

.PHONY: install uninstall test
