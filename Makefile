EMACS ?= emacs
LIB   ?= $(HOME)/.emacs.d/lib
LOAD_PATH = -L . -L $(LIB)/ghostel/lisp -L $(LIB)/gptel -L $(LIB)/compat -L $(LIB)/transient/lisp

.PHONY: all compile checkdoc test clean

all: compile checkdoc test

compile:
	$(EMACS) --batch -Q $(LOAD_PATH) --eval '(setq byte-compile-error-on-warn t)' \
		-f batch-byte-compile ghostel-ai.el

checkdoc:
	$(EMACS) --batch -Q --eval '(let ((sentence-end-double-space nil) (inhibit-message t)) \
		(checkdoc-file "ghostel-ai.el") \
		(when (get-buffer "*Warnings*") \
		  (with-current-buffer "*Warnings*" (princ (buffer-string))) (kill-emacs 1)))'

test:
	$(EMACS) --batch -Q $(LOAD_PATH) -l test/ghostel-ai-test.el -f ert-run-tests-batch-and-exit

clean:
	rm -f *.elc
