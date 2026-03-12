PREFIX ?= /usr/local

install:
	install -d $(PREFIX)/bin
	install -d $(PREFIX)/lib/todo
	install -m 755 td $(PREFIX)/bin/td
	install -m 644 lib/todo/*.sh $(PREFIX)/lib/todo/
	install -m 644 VERSION $(PREFIX)/VERSION
	install -m 755 hooks/pre-compact $(PREFIX)/bin/td-pre-compact

uninstall:
	rm -f $(PREFIX)/bin/td
	rm -f $(PREFIX)/bin/td-pre-compact
	rm -f $(PREFIX)/VERSION
	rm -rf $(PREFIX)/lib/todo

.PHONY: install uninstall
