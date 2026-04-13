;;; -*- lexical-binding: t; -*-
(setq package-enable-at-startup nil)
;; Emacs 31 warns when loading Elisp files without an explicit
;; `lexical-binding' cookie. Many third-party straight packages still omit it,
;; so keep the old default behavior without spamming startup warnings.
(setq internal--get-default-lexical-binding-function #'ignore)
