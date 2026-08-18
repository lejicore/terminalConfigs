;;; ox-ghostel-ssh-test.el --- Tests for Ghostel smart SSH -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)

(let ((source-directory
       (file-name-directory (directory-file-name
                             (file-name-directory (or load-file-name
                                                      buffer-file-name))))))
  (add-to-list 'load-path source-directory))

(require 'ox-ghostel-ssh)
(require 'ox-terminal)

(ert-deftest ox-ghostel-ssh-installs-only-a-ghostel-pre-spawn-hook ()
  (should (memq #'ox-ghostel-ssh-inject-environment
                ghostel-pre-spawn-hook))
  (should-not (memq #'ox-ghostel-ssh-inject-environment
                    vterm-mode-hook)))

(ert-deftest ox-ghostel-ssh-injection-is-dynamically-scoped ()
  (let ((global-environment (copy-sequence process-environment))
        (global-path (getenv "PATH")))
    ;; Match Ghostel's live construction: `append' shares its final list tail.
    (let* ((process-environment (append '("INSIDE_EMACS=ghostel")
                                        process-environment))
           (ox-ghostel-ssh-enable t)
           (ox-ghostel-ssh--real-ssh "/real/ssh")
           (ox-ghostel-ssh-runtime-directory "/runtime/"))
      (cl-letf (((symbol-function 'ox-ghostel-ssh--prepare)
                 (lambda () '(:source "/source" :compiled "/compiled"))))
        (ox-ghostel-ssh-inject-environment)
        (should (equal (getenv "OX_GHOSTEL_SSH_WRAPPER")
                       "/runtime/bin/ssh"))
        (should (equal (getenv "OX_GHOSTEL_SSH_REAL") "/real/ssh"))
        (should (equal (getenv "OX_GHOSTEL_SSH_NATIVE_TERM") "xterm-kitty"))
        (should (equal (getenv "OX_GHOSTEL_SSH_FALLBACK_TERMS")
                       "xterm-256color:xterm:dumb"))
        ;; Child programs must keep resolving ssh from the ordinary PATH.
        (should (equal (getenv "PATH") global-path))
        (should-not (member "/runtime/bin" exec-path))))
    (should (equal process-environment global-environment))))

(ert-deftest ox-ghostel-ssh-disabled-does-not-change-environment ()
  (let ((process-environment (copy-sequence process-environment))
        (before (copy-sequence process-environment))
        (ox-ghostel-ssh-enable nil))
    (ox-ghostel-ssh-inject-environment)
    (should (equal process-environment before))))

(ert-deftest ox-ghostel-ssh-vterm-creation-does-not-run-injection ()
  (let ((injected nil)
        (created (generate-new-buffer " *ox-smart-ssh-vterm*"))
        (real-require (symbol-function 'require)))
    (unwind-protect
        (cl-letf (((symbol-function 'require)
                   (lambda (feature &rest arguments)
                     (if (eq feature 'multi-vterm)
                         t
                       (apply real-require feature arguments))))
                  ((symbol-function 'multi-vterm)
                   (lambda () (switch-to-buffer created)))
                  ((symbol-function 'ox-ghostel-ssh-inject-environment)
                   (lambda () (setq injected t))))
          (should (eq (ox-terminal--vterm-create default-directory) created))
          (should-not injected))
      (when (buffer-live-p created) (kill-buffer created)))))

(ert-deftest ox-ghostel-ssh-resolves-real-ssh-before-wrapper-path ()
  (let* ((root (make-temp-file "ox-smart-ssh-resolve-" t))
         (wrapper-bin (expand-file-name "runtime/bin" root))
         (real-bin (expand-file-name "real-bin" root))
         (wrapper (expand-file-name "ssh" wrapper-bin))
         (real (expand-file-name "ssh" real-bin))
         (ox-ghostel-ssh-runtime-directory
          (file-name-as-directory (expand-file-name "runtime" root)))
         (process-environment (copy-sequence process-environment)))
    (unwind-protect
        (progn
          (make-directory wrapper-bin t)
          (make-directory real-bin t)
          (dolist (file (list wrapper real))
            (write-region "#!/bin/sh\n" nil file nil 'silent)
            (set-file-modes file #o700))
          (setenv "PATH" (mapconcat #'identity (list wrapper-bin real-bin)
                                     path-separator))
          (should (equal (ox-ghostel-ssh-resolve-real-executable) real)))
      (delete-directory root t))))

(ert-deftest ox-ghostel-ssh-rejects-command-injection-in-term-names ()
  (let ((ox-ghostel-ssh-native-term "xterm-kitty;touch-pwned"))
    (should-error (ox-ghostel-ssh--validate-configuration)))
  (let ((ox-ghostel-ssh-native-term "xterm-kitty")
        (ox-ghostel-ssh-fallback-terms '("xterm" "bad$(command)")))
    (should-error (ox-ghostel-ssh--validate-configuration))))

(ert-deftest ox-ghostel-ssh-compiled-paths-cover-char-and-hex-layouts ()
  (let ((ox-ghostel-ssh-native-term "xterm-kitty"))
    (should (equal (ox-ghostel-ssh--compiled-paths "/db/")
                   '("/db/x/xterm-kitty" "/db/78/xterm-kitty")))))

(ert-deftest ox-ghostel-ssh-wrapper-installation-is-private-and-executable ()
  (let* ((root (make-temp-file "ox-smart-ssh-install-" t))
         (ox-ghostel-ssh-runtime-directory
          (file-name-as-directory (expand-file-name "runtime" root))))
    (unwind-protect
        (let ((target (ox-ghostel-ssh--install-wrapper)))
          (should (equal target (expand-file-name "runtime/bin/ssh" root)))
          (should (file-executable-p target))
          (should (ox-ghostel-ssh--same-file-contents-p
                   target (ox-ghostel-ssh--wrapper-source))))
      (delete-directory root t))))

(provide 'ox-ghostel-ssh-test)
;;; ox-ghostel-ssh-test.el ends here
