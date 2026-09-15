;;; ox-window-zoom.el --- Perspective-local reversible window zoom -*- lexical-binding: t; -*-

;;; Commentary:
;; Keep a native window state for each zoomed perspective.  The state is
;; deliberately process-local: persp-mode's persisted window configuration is
;; kept in sync with the pre-zoom state while a perspective is zoomed, and the
;; transient zoomed display is reapplied when that perspective is activated.

;;; Code:

(require 'cl-lib)
(require 'persp-mode)

(declare-function get-current-persp "persp-mode" (&optional frame window))
(declare-function get-frame-persp "persp-mode" (&optional frame))
(declare-function persp-frame-save-state "persp-mode"
                  (&optional frame set-persp-special-last-buffer))
(declare-function persp-asave-on-exit "persp-mode" (&optional interactive-query opt))
(declare-function persp-special-last-buffer-make-current "persp-mode" ())
(declare-function persp-window-state-get "persp-mode"
                  (&optional frame window writable))
(declare-function persp-window-state-put "persp-mode"
                  (window-configuration &optional frame window))

(defgroup ox-window-zoom nil
  "Reversible window zoom for perspective-backed workspaces."
  :group 'persp-mode)

(defvar ox-window-zoom--states (make-hash-table :test #'eq)
  "Pre-zoom window states keyed by persp-mode perspective objects.
The hash is runtime-only and is cleared when persp-mode is disabled or a
perspective is killed.")

(defun ox-window-zoom--perspective (&optional frame window)
  "Return the persp-mode perspective for WINDOW or FRAME."
  (if (fboundp 'get-current-persp)
      (get-current-persp frame window)
    (get-frame-persp frame)))

(defun ox-window-zoom--state (perspective)
  "Return the saved zoom state for PERSPECTIVE, or nil."
  (gethash perspective ox-window-zoom--states))

(defun ox-window-zoom--capture-state (frame)
  "Capture FRAME's native window state in the persp-mode-compatible form."
  (if (fboundp 'persp-window-state-get)
      (persp-window-state-get frame (frame-root-window frame) t)
    (window-state-get (frame-root-window frame) t)))

(defun ox-window-zoom--restore-state (state frame)
  "Restore STATE into FRAME using persp-mode's native state wrapper."
  (if (fboundp 'persp-window-state-put)
      (persp-window-state-put state frame (frame-root-window frame))
    (window-state-put state (frame-root-window frame) t)))

(defun ox-window-zoom--save-perspective-state (perspective state)
  "Keep PERSPECTIVE's persp-mode window configuration equal to STATE."
  (if perspective
      (setf (persp-window-conf perspective) state)
    (setq persp-nil-wconf state)))

(defun ox-window-zoom--around-persp-frame-save-state
    (original &optional frame set-persp-special-last-buffer)
  "Prevent persp-mode from persisting a zoomed display instead of its layout."
  (let* ((frame (or frame (selected-frame)))
         (perspective (and (frame-live-p frame)
                           (get-frame-persp frame)))
         (state (and (frame-live-p frame)
                     (ox-window-zoom--state perspective))))
    (if (not state)
        (funcall original frame set-persp-special-last-buffer)
      (when (and set-persp-special-last-buffer
                 (fboundp 'persp-special-last-buffer-make-current))
        (with-selected-frame frame
          (persp-special-last-buffer-make-current)))
      (ox-window-zoom--save-perspective-state perspective state))))

(defun ox-window-zoom--around-persp-asave-on-exit (original &rest args)
  "Save any active zoom's underlying state, then release runtime state."
  (unwind-protect
      (apply original args)
    (ox-window-zoom--clear-states)))

(defun ox-window-zoom--activate-perspective (type frame-or-window perspective)
  "Reapply a zoomed display after persp-mode activates PERSPECTIVE."
  (when (and (eq type 'frame)
             (frame-live-p frame-or-window)
             (ox-window-zoom--state perspective))
    (with-selected-frame frame-or-window
      (delete-other-windows (frame-selected-window frame-or-window)))))

(defun ox-window-zoom--forget-perspective (perspective)
  "Discard runtime zoom state for PERSPECTIVE before it is killed."
  (remhash perspective ox-window-zoom--states))

(defun ox-window-zoom--clear-states (&rest _)
  "Discard all runtime zoom state when persp-mode is disabled."
  (clrhash ox-window-zoom--states))

;;;###autoload
(defun ox-window-zoom-toggle ()
  "Toggle a reversible zoom of the selected window in the current perspective.
In an unzoomed perspective, a single-window layout is left unchanged."
  (interactive)
  (let* ((frame (selected-frame))
         (perspective (ox-window-zoom--perspective frame))
         (state (ox-window-zoom--state perspective))
         (window (selected-window)))
    (cond
     (state
      (condition-case err
          (progn
            (ox-window-zoom--restore-state state frame)
            (remhash perspective ox-window-zoom--states)
            (message "Window zoom restored in perspective %s"
                     (if perspective (persp-name perspective) "none")))
        (error
         (message "Could not restore window zoom: %S" err))))
     ((one-window-p t)
      (message "Window zoom requires at least two windows"))
     (t
      (let ((saved-state (ox-window-zoom--capture-state frame)))
        (condition-case err
            (progn
              (puthash perspective saved-state ox-window-zoom--states)
              (delete-other-windows window)
              ;; Keep direct persp-mode subset saves from serializing the
              ;; temporary one-window display.
              (ox-window-zoom--save-perspective-state perspective saved-state)
              (message "Window zoom enabled in perspective %s"
                       (if perspective (persp-name perspective) "none")))
          (error
           (remhash perspective ox-window-zoom--states)
           (message "Could not zoom window: %S" err))))))))

(advice-add 'persp-frame-save-state :around
            #'ox-window-zoom--around-persp-frame-save-state)
(advice-add 'persp-asave-on-exit :around
            #'ox-window-zoom--around-persp-asave-on-exit)
(add-hook 'persp-activated-functions #'ox-window-zoom--activate-perspective)
(add-hook 'persp-before-kill-functions #'ox-window-zoom--forget-perspective)

(provide 'ox-window-zoom)
;;; ox-window-zoom.el ends here
