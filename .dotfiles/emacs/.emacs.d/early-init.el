;;; -*- lexical-binding: t; -*-
(setq package-enable-at-startup nil)
;; Emacs 31 warns when loading Elisp files without an explicit
;; `lexical-binding' cookie. Many third-party straight packages still omit it,
;; so keep the old default behavior without spamming startup warnings.
(setq internal--get-default-lexical-binding-function #'ignore)

;; Very early, before magit/forge/evil-collection-forge load.
(setq forge-add-default-bindings nil)

;; Compatibility shim for the current Emacs 31 + Magit stack. (need a more
;; recent Emacs commit build)
(eval-and-compile
  (unless (fboundp 'set-local)
    (defun set-local (variable value)
      "Make VARIABLE buffer-local and set it to VALUE."
      (set (make-local-variable variable) value))))
