;;; ox-persp-persistence-test.el --- Save policy regression -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'persp-mode)

;; Load only the policy and its registration from the canonical config.  Avoid
;; starting the user's daemon, processes, or package bootstrap in this test.
(with-temp-buffer
  (insert-file-contents
   (expand-file-name "../Emacs.org" (file-name-directory load-file-name)))
  (goto-char (point-min))
  (search-forward "    (defun ox/persp-buffer-persistable-p")
  (beginning-of-line)
  (let ((start (point)))
    (search-forward "    (defun consult-persp-buffer")
    (beginning-of-line)
    (eval-region start (point))))

(defvar my-org-files)

(ert-deftest ox-persp-persistence-save-policy ()
  (let* ((my-org-files '("/tmp/policy-agenda.org"))
         (persp-common-buffer-filter-functions nil)
         (persp-filter-save-buffers-functions
          '(ox/persp-buffer-save-filter))
         (buffers nil)
         (persp (make-persp :name "policy-test")))
    (unwind-protect
        (cl-labels ((make (name mode &optional file directory)
                     (let ((b (generate-new-buffer name)))
                       (push b buffers)
                       (with-current-buffer b
                         (setq major-mode mode
                               buffer-file-name file
                               default-directory (or directory "/tmp/")))
                       b)))
          (let* ((local (make "policy-source" 'emacs-lisp-mode "/tmp/policy.el"))
                 (org (make "policy-org" 'org-mode "/tmp/policy.org"))
                 (nonfile (make "policy-notes" 'org-mode))
                 (indirect (make-indirect-buffer org "policy-indirect" t))
                 (agent (make "policy-agent" 'agent-shell-mode))
                 (vterm (make "policy-vterm" 'vterm-mode))
                 (remote (make "policy-remote" 'fundamental-mode
                               "/ssh:policy.invalid:/tmp/file"))
                 (dired (make "policy-dired" 'dired-mode nil
                              "/ssh:policy.invalid:/tmp/"))
                 (agenda (make "policy-agenda" 'org-mode "/tmp/policy-agenda.org")))
            (push indirect buffers)
            ;; No remote resource is visited or process started.  Exercise the
            ;; installed serializer, including its actual filter polarity.
            (setf (persp-buffers persp) (copy-sequence buffers))
            (let* ((saved (persp-buffers-to-savelist persp))
                   (names (mapcar #'cadr saved)))
              (dolist (b (list local org nonfile indirect))
                (should (member (buffer-name b) names)))
              (dolist (b (list agent vterm remote dired agenda))
                (should-not (member (buffer-name b) names)))
              ;; Saving must not remove excluded buffers from live membership.
              (should (= (length (persp-buffers persp)) (length buffers))))))
      (mapc #'kill-buffer buffers))))

(ert-deftest ox-persp-persistence-dead-buffer ()
  (let ((b (generate-new-buffer "policy-dead")))
    (kill-buffer b)
    (should-not (ox/persp-buffer-persistable-p b))))
