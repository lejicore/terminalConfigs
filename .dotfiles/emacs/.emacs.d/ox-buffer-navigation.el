;;; ox-buffer-navigation.el --- Terminal/editing buffer navigation -*- lexical-binding: t; -*-

;;; Commentary:
;; Window alternate-buffer history is primary.  A small perspective-local
;; buffer-object history covers deleted/recreated windows without interned
;; per-perspective variables or mutable buffer names.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ox-workspace)
(require 'ox-terminal)

(declare-function safe-persp-buffers "persp-mode" (perspective))

(defgroup ox-buffer-navigation nil
  "Perspective-local editing buffer navigation."
  :group 'ox-workspace)

(defcustom ox-buffer-navigation-history-limit 8
  "Maximum editing buffers retained per perspective."
  :type 'integer
  :group 'ox-buffer-navigation)

(defvar ox-buffer-navigation--history (make-hash-table :test #'equal))

(defun ox-buffer-navigation--perspective-contains-p (buffer perspective)
  "Return non-nil when BUFFER is associated with PERSPECTIVE."
  (or (not (fboundp 'safe-persp-buffers))
      (memq buffer (safe-persp-buffers perspective))))

(defun ox-buffer-navigation--editing-buffer-p (buffer perspective)
  "Return non-nil when BUFFER is a live editing buffer for PERSPECTIVE."
  (and (buffer-live-p buffer)
       (not (minibufferp buffer))
       (not (string-prefix-p " " (buffer-name buffer)))
       (not (ox-terminal-buffer-p buffer))
       (ox-buffer-navigation--perspective-contains-p buffer perspective)))

(defun ox-buffer-navigation--clean-history (owner-id perspective)
  "Clean and return OWNER-ID's editing history for PERSPECTIVE."
  (let ((history
         (seq-filter
          (lambda (buffer)
            (ox-buffer-navigation--editing-buffer-p buffer perspective))
          (gethash owner-id ox-buffer-navigation--history))))
    (puthash owner-id history ox-buffer-navigation--history)
    history))

(cl-defun ox-buffer-navigation-record-buffer
    (buffer &optional (perspective (ox-workspace-current-perspective)))
  "Record editing BUFFER for PERSPECTIVE using buffer-object identity."
  (let* ((owner-id (ox-workspace-id perspective)))
    (when (ox-buffer-navigation--editing-buffer-p buffer perspective)
      (let ((history (cons buffer
                           (delq buffer
                                 (ox-buffer-navigation--clean-history
                                  owner-id perspective)))))
        (when (> (length history) ox-buffer-navigation-history-limit)
          (setcdr (nthcdr (1- ox-buffer-navigation-history-limit) history) nil))
        (puthash owner-id history ox-buffer-navigation--history)))))

(defun ox-buffer-navigation-track-selected-buffer (&optional frame)
  "Record the selected editing buffer in FRAME when appropriate."
  (let ((window (if (frame-live-p frame)
                    (frame-selected-window frame)
                  (selected-window))))
    (when (window-live-p window)
      (ox-buffer-navigation-record-buffer (window-buffer window)))))

(defun ox-buffer-navigation-track-window-buffer (window)
  "Record the editing buffer displayed by changed WINDOW."
  (when (window-live-p window)
    (ox-buffer-navigation-record-buffer (window-buffer window))))

(defun ox-buffer-navigation--window-candidate (window perspective)
  "Return WINDOW's most recent editing buffer for PERSPECTIVE."
  (cl-loop for entry in (window-prev-buffers window)
           for buffer = (car entry)
           when (ox-buffer-navigation--editing-buffer-p buffer perspective)
           return buffer))

(cl-defun ox-buffer-navigation-last-editing-buffer
    (&optional (window (selected-window))
               (perspective (ox-workspace-current-perspective)))
  "Return the most relevant editing buffer for WINDOW and PERSPECTIVE."
  (let* ((owner-id (ox-workspace-id perspective))
         (history (ox-buffer-navigation--clean-history owner-id perspective)))
    (or (and (window-live-p window)
             (ox-buffer-navigation--window-candidate window perspective))
        (car history))))

(defun ox-buffer-navigation-switch-to-editing-buffer ()
  "Return from a terminal to its most relevant editing buffer.
Outside a terminal, preserve Evil/Emacs alternate-buffer behavior."
  (interactive)
  (if (ox-terminal-buffer-p (current-buffer))
      (if-let* ((target (ox-buffer-navigation-last-editing-buffer)))
          (let* ((window (selected-window))
                 (terminal (current-buffer))
                 (entry (list terminal
                              (copy-marker (window-start window))
                              (copy-marker (window-point window))))
                 (previous (cl-remove terminal (window-prev-buffers window)
                                      :key #'car :test #'eq)))
            (switch-to-buffer target)
            ;; Evil's C-^ uses `window-prev-buffers'.  Record the terminal
            ;; explicitly because batch/edge window configurations do not
            ;; always update that list during `switch-to-buffer'.
            (set-window-prev-buffers window (cons entry previous)))
        (user-error "No editing buffer recorded for this perspective"))
    (if (fboundp 'evil-switch-to-windows-last-buffer)
        (evil-switch-to-windows-last-buffer)
      (switch-to-prev-buffer))))

(defun ox-buffer-navigation-after-terminal-kill (owner-id window sequence)
  "Select a sensible buffer after terminal SEQUENCE owned by OWNER-ID dies."
  (run-at-time
   0.05 nil
   (lambda ()
     (when (window-live-p window)
       (let* ((buffers (ox-terminal--buffers-for-owner owner-id))
              (target (or (cl-find-if
                           (lambda (buffer)
                             (> (buffer-local-value
                                 'ox-terminal-created-sequence buffer)
                                sequence))
                           buffers)
                          (car (last buffers))
                          (ox-buffer-navigation--owner-fallback owner-id))))
         (when (buffer-live-p target)
           (set-window-buffer window target)))))))

(defun ox-buffer-navigation--owner-fallback (owner-id)
  "Return OWNER-ID's first live non-terminal fallback and clean its history."
  (let ((history
         (seq-filter
          (lambda (buffer)
            (and (buffer-live-p buffer)
                 (not (minibufferp buffer))
                 (not (string-prefix-p " " (buffer-name buffer)))
                 (not (ox-terminal-buffer-p buffer))))
          (gethash owner-id ox-buffer-navigation--history))))
    (if history
        (puthash owner-id history ox-buffer-navigation--history)
      (remhash owner-id ox-buffer-navigation--history))
    (car history)))

(add-hook 'window-selection-change-functions
          #'ox-buffer-navigation-track-selected-buffer)
(add-hook 'window-buffer-change-functions
          #'ox-buffer-navigation-track-window-buffer)

;; Compatibility for callers that previously updated or used name histories.
(defalias 'my/get-persp-non-vterm-current-buffer
  #'ox-buffer-navigation-track-selected-buffer)
(defalias 'my/switch-to-persp-last-non-vterm-buffer
  #'ox-buffer-navigation-switch-to-editing-buffer)

(provide 'ox-buffer-navigation)
;;; ox-buffer-navigation.el ends here
