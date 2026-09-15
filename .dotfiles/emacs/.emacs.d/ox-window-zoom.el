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
(declare-function persp-restore-window-conf "persp-mode"
                  (&optional frame persp new-frame-p))
(declare-function persp-activate "persp-mode"
                  (persp &optional frame-or-window new-frame-p))
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

(defvar ox-window-zoom--inhibit nil
  "Non-nil while ox-window-zoom is performing its own window mutations.")

(defconst ox-window-zoom--user-structural-commands
  '(split-window split-window-below split-window-right
    delete-window delete-other-windows
    enlarge-window shrink-window
    enlarge-window-horizontally shrink-window-horizontally
    balance-windows fit-window-to-buffer maximize-window)
  "Commands which represent an explicit request to change window layout.
The low-level primitives advised below are also used by display machinery;
`this-command' distinguishes those calls from an interactive workspace edit.")

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
  (let ((ox-window-zoom--inhibit t))
    (if (fboundp 'persp-window-state-put)
        (persp-window-state-put state frame (frame-root-window frame))
      (window-state-put state (frame-root-window frame) t))))

(defun ox-window-zoom--capture-live-pane (window)
  "Capture the mutable state of the currently magnified WINDOW."
  (list :buffer (window-buffer window)
        :point (window-point window)
        :start (window-start window)
        :hscroll (window-hscroll window)
        :vscroll (window-vscroll window)
        :prev-buffers (window-prev-buffers window)))

(defun ox-window-zoom--restore-live-pane (window pane)
  "Apply the live zoom PANE state to restored WINDOW."
  (let ((buffer (plist-get pane :buffer)))
    (when (buffer-live-p buffer)
      (set-window-buffer window buffer)
      (set-window-point window (plist-get pane :point))
      (set-window-start window (plist-get pane :start) t)
      (set-window-hscroll window (plist-get pane :hscroll))
      (set-window-vscroll window (plist-get pane :vscroll))
      (set-window-prev-buffers window (plist-get pane :prev-buffers)))))

(defun ox-window-zoom--state-leaf (state)
  "Return the first window-state leaf in STATE."
  (cond
   ((and (consp state) (listp (cdr state))
         (memq 'leaf state) (assq 'buffer state)) state)
   ((consp state)
    (or (ox-window-zoom--state-leaf (car state))
        (ox-window-zoom--state-leaf (cdr state))))))

(defun ox-window-zoom--selected-state-leaf-p (leaf)
  "Return non-nil when LEAF is the selected window-state leaf."
  (let ((buffer (and (consp leaf) (listp (cdr leaf)) (memq 'leaf leaf)
                     (assq 'buffer leaf))))
    (and buffer (assq 'selected (cddr buffer)))))

(defun ox-window-zoom--merge-live-pane-into-state (state pane-state)
  "Merge the live PANE-STATE contents into STATE's selected leaf.
Only the selected leaf's buffer history and display state are replaced;
STATE's saved geometry and other leaves remain unchanged."
  (let ((pane-leaf (ox-window-zoom--state-leaf pane-state)))
    (if (not pane-leaf)
        state
      (cl-labels
          ((merge (node)
             (cond
              ((ox-window-zoom--selected-state-leaf-p node)
               (mapcar
                (lambda (entry)
                  (if (and (consp entry)
                           (memq (car entry) '(buffer prev-buffers)))
                      (copy-tree (assq (car entry) pane-leaf))
                    entry))
                (copy-tree node)))
              ((consp node)
               (cons (merge (car node)) (merge (cdr node))))
              (t node))))
        (merge (copy-tree state))))))

(defun ox-window-zoom--state-for-persp-save (state frame)
  "Return STATE with the live zoom pane merged for persp-mode persistence."
  (ox-window-zoom--merge-live-pane-into-state
   state (window-state-get (frame-selected-window frame) t)))

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
      (ox-window-zoom--save-perspective-state
       perspective (ox-window-zoom--state-for-persp-save state frame)))))

(defun ox-window-zoom--around-persp-asave-on-exit (original &rest args)
  "Save any active zoom's underlying state, then release runtime state."
  (unwind-protect
      (apply original args)
    (ox-window-zoom--clear-states)))

(defun ox-window-zoom--around-persp-restore-window-conf (original &rest args)
  "Keep persp-mode's internal layout restore from leaving an active zoom."
  (let ((ox-window-zoom--inhibit t))
    (apply original args)))

(defun ox-window-zoom--around-persp-activate (original &rest args)
  "Keep the complete persp-mode activation transaction internal."
  (let ((ox-window-zoom--inhibit t))
    (apply original args)))

(defun ox-window-zoom--restore-active-state (perspective state frame)
  "Restore and clear STATE for PERSPECTIVE on FRAME.
Return non-nil only when restoration succeeds."
  (let ((pane (ox-window-zoom--capture-live-pane (frame-selected-window frame)))
        (ox-window-zoom--inhibit t))
    (condition-case err
        (progn
          ;; Restore the saved geometry and hidden windows first.  The
          ;; selected leaf is then updated with the state of the live zoom
          ;; pane, so buffer switches, quits, point, and scrolling are not
          ;; overwritten by the pre-zoom snapshot.
          (ox-window-zoom--restore-state state frame)
          (ox-window-zoom--restore-live-pane
           (frame-selected-window frame) pane)
          (remhash perspective ox-window-zoom--states)
          (message "Window zoom restored in perspective %s"
                   (if perspective (persp-name perspective) "none"))
          t)
      (error
       (message "Could not restore window zoom: %S" err)
       nil))))

(defun ox-window-zoom--explicit-user-structural-mutation-p ()
  "Return non-nil when the current call represents user layout intent."
  (memq this-command ox-window-zoom--user-structural-commands))

(defun ox-window-zoom--around-structural-mutation (original &rest args)
  "Leave zoom before applying a structural window mutation.
The mutation is applied to the restored perspective layout, never to the
temporary one-window presentation."
  (let* ((frame (selected-frame))
         (perspective (ox-window-zoom--perspective frame))
         (state (ox-window-zoom--state perspective)))
    (if (or ox-window-zoom--inhibit
            (not state)
            (not (ox-window-zoom--explicit-user-structural-mutation-p)))
        (apply original args)
      (let ((ox-window-zoom--inhibit t))
        (when (ox-window-zoom--restore-active-state perspective state frame)
          (apply original args))))))

(defun ox-window-zoom--activate-perspective (type frame-or-window perspective)
  "Reapply a zoomed display after persp-mode activates PERSPECTIVE."
  (when (and (eq type 'frame)
             (frame-live-p frame-or-window)
             (ox-window-zoom--state perspective))
    (let ((ox-window-zoom--inhibit t))
      (with-selected-frame frame-or-window
        (delete-other-windows (frame-selected-window frame-or-window))))))

(defun ox-window-zoom--forget-perspective (perspective)
  "Discard runtime zoom state for PERSPECTIVE before it is killed."
  (remhash perspective ox-window-zoom--states))

(defun ox-window-zoom--clear-states (&rest _)
  "Discard all runtime zoom state when persp-mode is disabled."
  (clrhash ox-window-zoom--states))

(defun ox-window-zoom--add-advice (function advice)
  "Install ADVICE on FUNCTION once, including across module reloads."
  (unless (advice-member-p advice function)
    (advice-add function :around advice)))

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
      (ox-window-zoom--restore-active-state perspective state frame))
     ((one-window-p t)
      (message "Window zoom requires at least two windows"))
     (t
      (let ((saved-state (ox-window-zoom--capture-state frame)))
        (condition-case err
            (progn
              (puthash perspective saved-state ox-window-zoom--states)
              (let ((ox-window-zoom--inhibit t))
                (delete-other-windows window))
              ;; Keep direct persp-mode subset saves from serializing the
              ;; temporary one-window display.
              (ox-window-zoom--save-perspective-state perspective saved-state)
              (message "Window zoom enabled in perspective %s"
                       (if perspective (persp-name perspective) "none")))
          (error
           (remhash perspective ox-window-zoom--states)
           (message "Could not zoom window: %S" err))))))))

(ox-window-zoom--add-advice
 'persp-frame-save-state #'ox-window-zoom--around-persp-frame-save-state)
(ox-window-zoom--add-advice
 'persp-asave-on-exit #'ox-window-zoom--around-persp-asave-on-exit)
(ox-window-zoom--add-advice
 'persp-restore-window-conf #'ox-window-zoom--around-persp-restore-window-conf)
(ox-window-zoom--add-advice
 'persp-activate #'ox-window-zoom--around-persp-activate)
(dolist (function '(split-window delete-window delete-other-windows
                    enlarge-window shrink-window
                    enlarge-window-horizontally shrink-window-horizontally
                    balance-windows fit-window-to-buffer maximize-window))
  (ox-window-zoom--add-advice
   function #'ox-window-zoom--around-structural-mutation))
(add-hook 'persp-activated-functions #'ox-window-zoom--activate-perspective)
(add-hook 'persp-before-kill-functions #'ox-window-zoom--forget-perspective)

(provide 'ox-window-zoom)
;;; ox-window-zoom.el ends here
