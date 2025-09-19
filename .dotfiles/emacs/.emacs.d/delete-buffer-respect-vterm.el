;; -*- lexical-binding: t; -*-

;;; Code:
(defvar my/non-vterm-buffer-history-limit 5
    "Maximum number of non-vterm buffers remembered per perspective.")

(defun my/vterm-buffer-p (&optional buffer)
    "Return non-nil when BUFFER is a vterm buffer.
BUFFER can be a buffer object, buffer name or nil for `current-buffer'."
    (let ((buffer (cond
                      ((bufferp buffer) buffer)
                      ((stringp buffer) (get-buffer buffer))
                      (t (current-buffer)))))
        (when buffer
            (with-current-buffer buffer
                (derived-mode-p 'vterm-mode)))))


;;; --- Config ---------------------------------------------------------------
(defvar my/vterm-buffer-history-limit my/non-vterm-buffer-history-limit
    "Maximum number of vterm buffers remembered per perspective.")

;;; --- Helpers: perspective + classification --------------------------------

(defun my/persp-name ()
    (let ((persp (and (fboundp 'get-frame-persp) (get-frame-persp))))
        (cond
            ((and persp (fboundp 'safe-persp-name)) (safe-persp-name persp))
            (persp "global")
            (t "global"))))

(defun my/record-into-history (buffer)
    "Insert BUFFER (name) at front of the appropriate history for current persp."
    (let* ((buf (cond
                    ((bufferp buffer) buffer)
                    ((stringp buffer) (get-buffer buffer))
                    (t (current-buffer))))
              (name (and buf (buffer-name buf))))
        (when (and name (not (minibufferp buf)))
            (let* ((persp-name (my/persp-name))
                      (is-vterm (with-current-buffer buf (derived-mode-p 'vterm-mode)))
                      (limit (if is-vterm my/vterm-buffer-history-limit
                                 my/non-vterm-buffer-history-limit))
                      (sym (intern (format "my/%s-buffer-history-on-%s-persp"
                                       (if is-vterm "vterm" "non-vterm") persp-name)))
                      (hist (when (boundp sym) (symbol-value sym)))
                      (hist (cons name (delete name hist))))
                ;; truncate to LIMIT
                (let ((tail hist) (count 1))
                    (while (and tail (< count limit))
                        (setq tail (cdr tail))
                        (setq count (1+ count)))
                    (when tail (setcdr tail nil)))
                (set sym hist)))))

(defun my/history (kind)
    "Return the history list for KIND ('vterm or 'non-vterm) on current persp."
    (let* ((persp-name (my/persp-name))
              (sym (intern (format "my/%s-buffer-history-on-%s-persp"
                               (if (eq kind 'vterm) "vterm" "non-vterm")
                               persp-name))))
        (when (boundp sym) (symbol-value sym))))

(defun my/prev-of-same-class (killed-buffer)
    "Given KILLED-BUFFER, pick the prior buffer of the same class in history."
    (let* ((is-vterm (my/vterm-buffer-p killed-buffer))
              (kind (if is-vterm 'vterm 'non-vterm))
              (hist (my/history kind))
              (kname (buffer-name (get-buffer killed-buffer)))
              ;; choose the first buffer in hist that is not the killed one and still live
              (target (seq-find (lambda (n) (and (not (equal n kname))
                                                (get-buffer n)))
                          hist)))
        target))

;;; --- Public recorders (compatible with existing calls) ----------------

(defun my/get-persp-non-vterm-current-buffer (&rest _)
    (let ((buf (current-buffer)))
        (unless (or (my/vterm-buffer-p buf) (minibufferp buf))
            (my/record-into-history buf))))

(defun my/get-persp-vterm-current-buffer (&rest _)
    (let ((buf (current-buffer)))
        (when (and (my/vterm-buffer-p buf) (not (minibufferp buf)))
            (my/record-into-history buf))))

(defun my/switch-to-persp-last-non-vterm-buffer ()
    "Jump to the most recent non-vterm buffer for the current perspective.
From a vterm buffer go to the latest non-vterm buffer, otherwise jump to the
previous non-vterm buffer if one exists. Fallback to the default last buffer
command when no history is available."
    (interactive)
    (unless (my/vterm-buffer-p)
        (my/get-persp-non-vterm-current-buffer))
    (let* ((persp (and (fboundp 'get-frame-persp) (get-frame-persp)))
              (persp-name (cond
                              ((and persp (fboundp 'safe-persp-name)) (safe-persp-name persp))
                              (persp "global")
                              (t "global")))
              (history-symbol (intern (format "my/non-vterm-buffer-history-on-%s-persp"
                                          persp-name)))
              (history (when (boundp history-symbol)
                           (symbol-value history-symbol)))
              (target-name (cond
                               ((null history) nil)
                               ((my/vterm-buffer-p) (car history))
                               ((cdr history) (cadr history))
                               (t (car history)))))
        (cond
            ((and target-name (get-buffer target-name))
                (switch-to-buffer target-name))
            ((fboundp 'evil-switch-to-windows-last-buffer)
                (evil-switch-to-windows-last-buffer))
            (t
                (message "No recorded non-vterm buffer")))))

;;; ------------------- Smart kill: command -------------------------------

(defun my/kill-current-buffer-smart (&optional arg)
    "Kill current buffer, then jump to the previous buffer of the *same class*.
If killing a vterm, jump to the previous vterm (if any).
If killing a non-vterm, jump to the previous non-vterm (if any).
With ARG, pass it through to `kill-current-buffer'."
    (interactive "P")
    ;; ensure histories are up to date for the current buffer before killing
    (my/record-into-history (current-buffer))
    (let* ((buf (current-buffer))
              (target (my/prev-of-same-class buf)))
        (kill-current-buffer)
        (cond
            ((and target (get-buffer target)) (switch-to-buffer target))
            ;; fall back to "last window buffer" if available
            ((fboundp 'evil-switch-to-windows-last-buffer)
                (evil-switch-to-windows-last-buffer))
            ;; otherwise whatever Emacs picks next is fine; just message
            (t (message "No recorded buffer of the same class; stayed on default next buffer.")))))

;; If you prefer to *replace* the default `C-x k' behavior:
;; (global-set-key (kbd "C-x k") #'my/kill-current-buffer-smart)

;; OR: transparently advise `kill-current-buffer` so anything that calls it benefits:
(defun my/kill-current-buffer--around (orig-fn &rest args)
    (my/record-into-history (current-buffer))
    (let* ((buf (current-buffer))
              (target (my/prev-of-same-class buf)))
        (prog1 (apply orig-fn args)
            (cond
                ((and target (get-buffer target)) (switch-to-buffer target))
                ((fboundp 'evil-switch-to-windows-last-buffer)
                    (evil-switch-to-windows-last-buffer))
                (t (message "No recorded buffer of the same class; stayed on default next buffer."))))))

;;; --- Jump after any kill (vterm or not) ------------------------------------

(defvar my/kill-buffer-jump-commands
    '(kill-this-buffer kill-current-buffer kill-buffer my/kill-current-buffer-smart)
    "Interactive commands that should trigger `my/kill-buffer-jump-same-class'.
Commands can opt-in dynamically by putting the property
`my/kill-buffer-jump-same-class' on their symbol.")

(defun my/kill-buffer--command-triggers-jump-p (buffer)
    "Return non-nil when the current kill should trigger a jump.
BUFFER is the buffer being killed."
    (let* ((cmd (or this-command (and (boundp 'real-this-command) real-this-command)))
             (trigger (or (memq cmd my/kill-buffer-jump-commands)
                          (and (symbolp cmd)
                               (get cmd 'my/kill-buffer-jump-same-class))
                          (and (null cmd)
                               (my/vterm-buffer-p buffer)))))
        trigger))

(defun my/kill-buffer-jump-same-class ()
  "When the current buffer is being killed, schedule a jump to a prior buffer
of the same class (vterm/non-vterm) for the selected window."
  (let* ((buf (current-buffer)))
    ;; Don’t interfere with minibuffer or internal buffers (names starting with space).
    (unless (or (minibufferp buf)
                (string-prefix-p " " (buffer-name buf))
                (not (eq buf (window-buffer (selected-window))))
                (not (my/kill-buffer--command-triggers-jump-p buf)))
      ;; Make sure this buffer was recorded at least once.
      ;; (Important for vterm C-d where our around-advice is not involved.)
      (my/record-into-history buf)
      (let ((target (my/prev-of-same-class buf)))
        ;; Defer the actual switch until after the kill finishes.
        (when target
          (run-at-time
           0 nil
           (lambda (tgt)
             (when (and tgt (get-buffer tgt) (window-live-p (selected-window)))
               (switch-to-buffer tgt)))
           target))))))

;; Install globally; Emacs will run this in the context of the buffer being killed.
(add-hook 'kill-buffer-hook #'my/kill-buffer-jump-same-class)

;;; --- Keep histories fresh on window/buffer changes --------------------------

(defun my/persp-track-current-buffer (&rest _)
    "Record the selected window's buffer into the appropriate history."
    (let ((buf (window-buffer (selected-window))))
        (unless (minibufferp buf)
            (my/record-into-history buf))))

;; These hooks are efficient and keep both histories accurate as you navigate.
(add-hook 'window-selection-change-functions #'my/persp-track-current-buffer)
(add-hook 'window-buffer-change-functions    #'my/persp-track-current-buffer)

;;; --- Existing bindings from your snippet stay valid ------------------------

;; Keep your vterm entry points updating non-vterm history before jumping to vterm
(advice-add #'multi-vterm :before #'my/get-persp-non-vterm-current-buffer)
(advice-add #'vterm        :before #'my/get-persp-non-vterm-current-buffer)

(with-eval-after-load 'evil
    (dolist (state '(normal visual insert))
        (evil-define-key state global-map (kbd "C-6")
            #'my/switch-to-persp-last-non-vterm-buffer)))
(provide 'delete-buffer-respect-vterm.el)
;;; delete-buffer-respect-vterm.el ends here
