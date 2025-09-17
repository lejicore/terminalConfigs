;; -*- lexical-binding: t; -*-

;;; Code:
(defvar my/vterm-buffer-created-at-table (make-hash-table :test 'eq)
    "Track the first-seen timestamp for each live vterm buffer.")

(defvar my/vterm-rename-timer nil
    "Timer handle used to coalesce vterm rename requests.")

(defvar my/vterm-rename-lock nil
    "Non-nil while a vterm renaming pass is running.")

(defvar my/vterm-rename-run-id 0
    "Monotonic counter used to generate unique temporary vterm names.")

(defun my/vterm--buffer-created-at (buffer)
    "Return BUFFER creation time, recording it when unknown."
    (when (buffer-live-p buffer)
        (or (gethash buffer my/vterm-buffer-created-at-table)
            (let ((stamp (current-time)))
                (puthash buffer stamp my/vterm-buffer-created-at-table)
                stamp))))

(defun my/vterm--cleanup-tracking ()
    "Remove dead buffers from `my/vterm-buffer-created-at-table'."
    (maphash (lambda (buf _)
                 (unless (buffer-live-p buf)
                     (remhash buf my/vterm-buffer-created-at-table)))
        my/vterm-buffer-created-at-table))

(defun my/vterm--collect ()
    "Return all live buffers currently in `vterm-mode'."
    (cl-remove-if-not
        (lambda (buf)
            (and (buffer-live-p buf)
                (eq (buffer-local-value 'major-mode buf) 'vterm-mode)))
        (buffer-list)))

(defun my/vterm--normalize-persp (persp)
    "Return a persp object for PERSP if available."
    (cond
        ((framep persp) (and (fboundp 'get-frame-persp) (get-frame-persp persp)))
        ((and (fboundp 'perspective-p) (perspective-p persp)) persp)
        (t nil)))

(defun my/vterm--current-persp ()
    "Return the currently active perspective object, or nil."
    (when (and (boundp 'persp-mode) persp-mode
              (fboundp 'get-current-persp))
        (get-current-persp)))

(defun my/vterm--persp-name (persp)
    "Return a printable name for PERSP."
    (let ((norm (my/vterm--normalize-persp persp)))
        (cond
            ((and norm (fboundp 'persp-name)) (persp-name norm))
            ((and (boundp 'persp-mode) persp-mode) "none")
            (t "main"))))

(defun my/vterm--sanitize-persp-name (persp)
    "Return a sanitized name for PERSP suitable for buffer names."
    (replace-regexp-in-string "[^A-Za-z0-9_-]" "_" (my/vterm--persp-name persp)))

(defun my/vterm--buffers-for-persp (persp)
    "Return vterm buffers that belong to PERSP."
    (let ((all (my/vterm--collect))
             (norm (my/vterm--normalize-persp persp)))
        (if (and norm (fboundp 'persp-buffers))
            (cl-intersection all (persp-buffers norm) :test #'eq)
            all)))

(defun my/vterm--sort (buffers)
    "Sort BUFFERS by creation time, falling back to recent usage order."
    (sort (copy-sequence buffers)
        (lambda (a b)
            (let ((ta (my/vterm--buffer-created-at a))
                     (tb (my/vterm--buffer-created-at b)))
                (cond
                    ((and ta tb) (time-less-p ta tb))
                    (ta t)
                    (tb nil)
                    (t (< (or (cl-position a (buffer-list)) most-positive-fixnum)
                           (or (cl-position b (buffer-list)) most-positive-fixnum))))))))

(defun my/vterm--rename-buffers (buffers formatter)
    "Rename BUFFERS using FORMATTER, preserving order.
FORMATTER receives the 1-based index of each buffer."
    (let ((sorted (my/vterm--sort buffers))
             (index 1))
        (dolist (buf sorted)
            (with-current-buffer buf
                (rename-buffer (funcall formatter index) t))
            (setq index (1+ index)))
        (not (null sorted))))

(defun my/vterm--activate-persp (persp)
    "Rename vterm buffers belonging to PERSP using simple names."
    (let ((buffers (my/vterm--buffers-for-persp persp)))
        (when buffers
            (my/vterm--rename-buffers
                buffers
                (lambda (index)
                    (format "*vterminal<%d>*" index)))
            t)))

(defun my/vterm--deactivate-persp (persp)
    "Rename vterm buffers belonging to PERSP using prefixed names."
    (when (and (boundp 'persp-mode) persp-mode)
        (let ((buffers (my/vterm--buffers-for-persp persp))
                 (prefix (my/vterm--sanitize-persp-name persp)))
            (when buffers
                (my/vterm--rename-buffers
                    buffers
                    (lambda (index)
                        (format "*vterminal@%s<%d>*" prefix index)))
                t))))

(defun my/vterm--with-rename-lock (fn)
    "Execute FN while holding the vterm rename lock."
    (unless my/vterm-rename-lock
        (setq my/vterm-rename-lock t)
        (unwind-protect (funcall fn)
            (setq my/vterm-rename-lock nil))))

(defun my/vterm--schedule-rename (&optional delay)
    "Schedule a vterm rename after DELAY seconds (defaults to 0.2)."
    (when (timerp my/vterm-rename-timer)
        (cancel-timer my/vterm-rename-timer))
    (setq my/vterm-rename-timer
        (run-with-timer (or delay 0.2) nil #'my/global-safe-rename-vterm-buffers)))

(defun my/global-safe-rename-vterm-buffers ()
    "Renumber vterm buffers in the current perspective without collisions."
    (interactive)
    (my/vterm--with-rename-lock
        (lambda ()
            (my/vterm--cleanup-tracking)
            (let ((persp (my/vterm--current-persp)))
                (when (my/vterm--activate-persp persp)
                    (my/update-vterm-count-modeline)
                    (when (bound-and-true-p doom-modeline-mode)
                        (force-mode-line-update t)))))))

(defun my/rename-persp-vterm-buffers ()
    "Manual entry point for renaming vterm buffers in the current perspective."
    (interactive)
    (my/global-safe-rename-vterm-buffers))

(defun my/vterm--register-buffer ()
    "Track a new vterm buffer and queue a rename."
    (my/vterm--buffer-created-at (current-buffer))
    (my/vterm-modeline-update-hook)
    (my/vterm--schedule-rename 0.1))

(defun my/vterm--cleanup-buffer ()
    "Forget a vterm buffer that is about to be killed."
    (remhash (current-buffer) my/vterm-buffer-created-at-table)
    (my/vterm-modeline-update-hook)
    (my/vterm--schedule-rename 0.2))

(add-hook 'vterm-mode-hook #'my/vterm--register-buffer)
(add-hook 'kill-buffer-hook
    (lambda ()
        (when (eq major-mode 'vterm-mode)
            (my/vterm--cleanup-buffer))))

(defun my/vterm--on-persp-activated (persp &rest _)
    "Handle perspective activation by refreshing vterm numbering."
    (my/global-safe-rename-vterm-buffers)
    (my/vterm--schedule-rename 0.2))

(defun my/vterm--on-persp-before-switch (new-persp old-persp)
    "Rename buffers belonging to the old perspective before switching."
    (ignore new-persp)
    (let ((old (my/vterm--normalize-persp old-persp)))
        (when old
            (my/vterm--deactivate-persp old))))

(defun my/vterm--setup-persp-hooks ()
    "Attach vterm rename helpers to perspective change hooks."
    (when (boundp 'persp-activated-functions)
        (add-hook 'persp-activated-functions #'my/vterm--on-persp-activated))
    (when (boundp 'persp-before-switch-functions)
        (add-hook 'persp-before-switch-functions #'my/vterm--on-persp-before-switch)))

(my/vterm--setup-persp-hooks)

(with-eval-after-load 'persp-mode
    (my/vterm--setup-persp-hooks))

(provide 'vterm-renamer)
;;; vterm-renamer.el ends here
