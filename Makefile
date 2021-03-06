all: build

config.mk:
	scripts/new-config "$(WATCH)" "$(NOTIFY)" "$(DOC)" "$(PREFIX)" "$(TARGETS)" > $@
-include config.mk

ifeq ($(WATCH),true)
STACK_FLAGS += --file-watch
endif
ifeq ($(NOTIFY),true)
STACK_FLAGS += --exec scripts/notify-build-success
endif
ifeq ($(DOC),true)
STACK_FLAGS += --haddock
endif
ifdef PREFIX
STACK_FLAGS += --local-install-root $(PREFIX)
endif
ifndef TARGETS
TARGETS := curly
endif

build:
	stack build $(STACK_FLAGS) $(TARGETS)

doc: STACK_FLAGS += --haddock
doc: build

install: STACK_FLAGS += --copy-bins
install: build

FORCE:
%/ChangeLog.md: FORCE
	scripts/changelog $* > $@

