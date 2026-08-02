;;; ox-terminal-test.el --- Tests for backend-neutral terminals -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'seq)

(let ((source-directory
       (file-name-directory (directory-file-name
                             (file-name-directory (or load-file-name
                                                      buffer-file-name))))))
  (add-to-list 'load-path source-directory))

(require 'ox-workspace)
(require 'ox-terminal)
(require 'ox-buffer-navigation)

(unless (fboundp 'vterm-mode)
  (define-derived-mode vterm-mode fundamental-mode "Test-VTerm"))
(unless (fboundp 'ghostel-mode)
  (define-derived-mode ghostel-mode fundamental-mode "Test-Ghostel"))

(defmacro ox-terminal-test--with-buffers (bindings &rest body)
  "Create managed terminal BINDINGS, evaluate BODY, then clean up.
Each binding is (SYMBOL OWNER SEQUENCE BACKEND)."
  (declare (indent 1) (debug t))
  `(let ,(mapcar (lambda (binding)
                   `(,(car binding) (generate-new-buffer
                                     ,(format " *ox-test-%s*" (car binding)))))
                 bindings)
     (unwind-protect
         (cl-letf (((symbol-function 'ox-terminal-live-p)
                    (lambda (&optional buffer)
                      (ox-terminal-managed-buffer-p buffer))))
           ,@(mapcar
              (lambda (binding)
                (pcase-let ((`(,symbol ,owner ,sequence ,backend) binding))
                  `(with-current-buffer ,symbol
                     (,(if (eq backend 'ghostel) 'ghostel-mode 'vterm-mode))
                     (setq-local ox-terminal-managed-p t
                                 ox-terminal-owner-id ,owner
                                 ox-terminal-owner-name ,owner
                                 ox-terminal-created-sequence ,sequence
                                 ox-terminal-id (format "stable-%s" ,sequence)
                                 ox-terminal-backend ',backend))))
              bindings)
           ,@body)
       (dolist (buffer (list ,@(mapcar #'car bindings)))
         (when (buffer-live-p buffer)
           (with-current-buffer buffer (setq ox-terminal-managed-p nil))
           (kill-buffer buffer))))))

(ert-deftest ox-terminal-order-is-creation-order ()
  (ox-terminal-test--with-buffers
      ((late "A" 30 ghostel) (early "A" 10 vterm) (middle "A" 20 ghostel))
    (cl-letf (((symbol-function 'ox-terminal--owner-id) (lambda (&optional _) "A")))
      (switch-to-buffer late)
      (switch-to-buffer early)
      (should (equal (ox-terminal-buffers) (list early middle late)))
      ;; Neither MRU changes nor a hypothetical perspective order is consulted.
      (switch-to-buffer middle)
      (should (equal (ox-terminal-buffers) (list early middle late))))))

(ert-deftest ox-terminal-dense-renumber-preserves-stable-ids ()
  (ox-terminal-test--with-buffers
      ((one "A" 1 vterm) (two "A" 2 ghostel)
       (three "A" 3 vterm) (four "A" 4 ghostel))
    (let ((surviving-ids
           (mapcar (lambda (buffer)
                     (buffer-local-value 'ox-terminal-id buffer))
                   (list one three four))))
      (with-current-buffer two (setq ox-terminal-managed-p nil))
      (kill-buffer two)
      (cl-letf (((symbol-function 'ox-workspace-perspective-by-id)
                 (lambda (_) nil)))
        (ox-terminal-renumber-owner "A"))
      (should (equal (mapcar #'buffer-name (list one three four))
                     '("*A-terminal*<1>" "*A-terminal*<2>" "*A-terminal*<3>")))
      (should (equal surviving-ids
                     (mapcar (lambda (buffer)
                               (buffer-local-value 'ox-terminal-id buffer))
                             (list one three four))))
      (should-not (seq-some (lambda (name) (string-match-p "<[0-9]+><[0-9]+>" name))
                            (mapcar #'buffer-name (list one three four)))))))

(ert-deftest ox-terminal-perspective-isolation-and-inactive-renumber ()
  (ox-terminal-test--with-buffers
      ((a1 "A" 1 vterm) (a2 "A" 2 ghostel) (a3 "A" 3 vterm)
       (b1 "B" 4 ghostel))
    (cl-letf (((symbol-function 'ox-terminal--owner-id)
               (lambda (&optional perspective) (or perspective "B")))
              ((symbol-function 'ox-workspace-perspective-by-id)
               (lambda (_) nil)))
      (should (equal (ox-terminal-buffers "A") (list a1 a2 a3)))
      (should (equal (ox-terminal-buffers "B") (list b1)))
      (with-current-buffer a2 (setq ox-terminal-managed-p nil))
      (kill-buffer a2)
      ;; Current owner is B; the callback explicitly targets inactive owner A.
      (ox-terminal--run-scheduled-renumber "A")
      (should (equal (mapcar #'buffer-name (list a1 a3))
                     '("*A-terminal*<1>" "*A-terminal*<2>")))
      (should (equal (buffer-local-value 'ox-terminal-owner-id a3) "A")))))

(ert-deftest ox-terminal-mixed-backends-share-slots ()
  (ox-terminal-test--with-buffers
      ((one "mixed" 1 vterm) (two "mixed" 2 ghostel) (three "mixed" 3 ghostel))
    (cl-letf (((symbol-function 'ox-terminal--owner-id) (lambda (&optional _) "mixed")))
      (should (equal (mapcar (lambda (buffer)
                              (buffer-local-value 'ox-terminal-backend buffer))
                            (ox-terminal-buffers))
                     '(vterm ghostel ghostel)))
      (ox-terminal-switch-to-slot 2)
      (should (eq (current-buffer) two))
      (should-error (ox-terminal-switch-to-slot 5) :type 'user-error))))

(ert-deftest ox-terminal-unmanaged-backend-buffers-are-ignored ()
  (let ((vterm (generate-new-buffer " *manual-vterm*"))
        (ghostel (generate-new-buffer " *manual-ghostel*")))
    (unwind-protect
        (progn
          (with-current-buffer vterm (vterm-mode))
          (with-current-buffer ghostel (ghostel-mode))
          (cl-letf (((symbol-function 'ox-terminal--owner-id)
                     (lambda (&optional _) "A")))
            (should (ox-terminal-buffer-p vterm))
            (should (ox-terminal-buffer-p ghostel))
            (should-not (ox-terminal-buffers))))
      (kill-buffer vterm)
      (kill-buffer ghostel))))

(ert-deftest ox-terminal-backend-resolution-and-existing-metadata ()
  (let ((ox-terminal-default-backend 'ghostel)
        override)
    (cl-letf (((symbol-function 'ox-terminal-perspective-backend)
               (lambda (&optional _) override)))
      (should (eq (ox-terminal-resolved-backend 'perspective) 'ghostel))
      (setq override 'vterm)
      (should (eq (ox-terminal-resolved-backend 'perspective) 'vterm))
      (setq override nil
            ox-terminal-default-backend 'vterm)
      (should (eq (ox-terminal-resolved-backend 'perspective) 'vterm))))
  (ox-terminal-test--with-buffers ((existing "A" 1 ghostel))
    (let ((ox-terminal-default-backend 'vterm))
      (should (eq (buffer-local-value 'ox-terminal-backend existing) 'ghostel)))))

(ert-deftest ox-terminal-perspective-backend-commands-and-global-toggle ()
  (let ((ox-terminal-default-backend 'vterm)
        override)
    (cl-letf (((symbol-function 'ox-workspace-current-perspective) (lambda () 'P))
              ((symbol-function 'ox-workspace-perspective-name) (lambda (&optional _) "P"))
              ((symbol-function 'set-persp-parameter)
               (lambda (_parameter value &optional _perspective)
                 (setq override value)))
              ((symbol-function 'delete-persp-parameter)
               (lambda (&rest _) (setq override nil)))
              ((symbol-function 'persp-parameter)
               (lambda (&rest _) override)))
      (ox-terminal-set-perspective-backend 'ghostel)
      (should (eq (ox-terminal-resolved-backend 'P) 'ghostel))
      (ox-terminal-clear-perspective-backend)
      (should (eq (ox-terminal-resolved-backend 'P) 'vterm))
      (ox-terminal-toggle-default-backend)
      (should (eq ox-terminal-default-backend 'ghostel)))))

(ert-deftest ox-terminal-dead-process-is-not-canonical ()
  (let ((buffer (generate-new-buffer " *dead-process-terminal*"))
        (ox-terminal--backends
         '((ghostel :buffer-p ignore :live-p ignore))))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq-local ox-terminal-managed-p t
                        ox-terminal-owner-id "A"
                        ox-terminal-created-sequence 1
                        ox-terminal-backend 'ghostel))
          (cl-letf (((symbol-function 'ox-terminal--owner-id)
                     (lambda (&optional _) "A")))
            (should-not (ox-terminal-buffers))))
      (with-current-buffer buffer (setq ox-terminal-managed-p nil))
      (kill-buffer buffer))))

(ert-deftest ox-terminal-create-records-resolved-backend ()
  (let ((ox-terminal--backends nil)
        (ox-terminal-default-backend 'ghostel)
        created)
    (ox-terminal-register-backend
     'ghostel
     :create (lambda (_) (setq created (generate-new-buffer " *fake-ghostel*")))
     :buffer-p (lambda (buffer) (eq buffer created))
     :live-p (lambda (_) t)
     :send-string #'ignore :send-return #'ignore :kill #'kill-buffer)
    (cl-letf (((symbol-function 'ox-workspace-current-perspective) (lambda () 'P))
              ((symbol-function 'ox-workspace-id) (lambda (&rest _) "P-id"))
              ((symbol-function 'ox-workspace-perspective-name) (lambda (&optional _) "P"))
              ((symbol-function 'ox-workspace-project-root) (lambda (&optional _) nil))
              ((symbol-function 'ox-workspace-perspective-by-id) (lambda (_) 'P))
              ((symbol-function 'persp-add-buffer) #'ignore)
              ((symbol-function 'persp-parameter) (lambda (&rest _) nil)))
      (unwind-protect
          (let ((buffer (ox-terminal-create)))
            (should (eq buffer created))
            (should (eq (buffer-local-value 'ox-terminal-backend buffer) 'ghostel))
            (should (equal (buffer-local-value 'ox-terminal-owner-id buffer) "P-id")))
        (when (buffer-live-p created)
          (with-current-buffer created (setq ox-terminal-managed-p nil))
          (kill-buffer created))))))

(ert-deftest ox-workspace-project-directory-selection ()
  (let ((editing (generate-new-buffer " *projectless-editing*")))
    (unwind-protect
        (with-current-buffer editing
          (setq default-directory "/tmp/projectless/")
          (cl-letf (((symbol-function 'ox-workspace-project-root)
                     (lambda (&optional perspective)
                       (and (eq perspective 'project) "/tmp/project/"))))
            (should (equal (ox-terminal-creation-directory 'project editing)
                           "/tmp/project/"))
            (should (equal (ox-terminal-creation-directory 'scratch editing)
                           "/tmp/projectless/"))
            (setq default-directory "/sshx:ledeb:~")
            (should (equal (ox-terminal-creation-directory 'scratch editing)
                           "/sshx:ledeb:~"))))
      (kill-buffer editing))))

(ert-deftest ox-workspace-project-identity-and-name-collisions ()
  (let ((parameters (make-hash-table :test #'equal))
        (perspectives '(one two)))
    (puthash (cons 'one ox-workspace-project-parameter) "/srv/a/app/" parameters)
    (puthash (cons 'two ox-workspace-project-parameter) "/srv/a/app/" parameters)
    (cl-letf (((symbol-function 'ox-workspace-perspectives) (lambda () perspectives))
              ((symbol-function 'persp-parameter)
               (lambda (parameter perspective)
                 (gethash (cons perspective parameter) parameters)))
              ((symbol-function 'persp-names) (lambda (&rest _) '("app"))))
      (should (equal (ox-workspace-perspectives-for-project "/srv/a/app")
                     '(one two)))
      (should (equal (ox-workspace-perspectives-for-project "/srv/b/app") nil))
      (should (equal (ox-workspace-unique-project-name "/srv/b/app") "app<2>")))))

(ert-deftest ox-workspace-ordinary-switch-does-not-attach-project ()
  (let (attached switched)
    (cl-letf (((symbol-function 'persp-switch)
               (lambda (name &rest _) (setq switched name)))
              ((symbol-function 'set-persp-parameter)
               (lambda (&rest args) (setq attached args))))
      (persp-switch "scratch")
      (should (equal switched "scratch"))
      (should-not attached))))

(ert-deftest ox-buffer-navigation-prefers-window-history-and-cleans-dead-buffers ()
  (let ((terminal (generate-new-buffer " *nav-terminal*"))
        (editing (generate-new-buffer "editing-file"))
        (dead (generate-new-buffer "dead-editing")))
    (unwind-protect
        (progn
          (with-current-buffer terminal
            (setq-local ox-terminal-managed-p t
                        ox-terminal-owner-id "A"
                        ox-terminal-created-sequence 1
                        ox-terminal-backend 'ghostel))
          (kill-buffer dead)
          (puthash "A" (list dead editing) ox-buffer-navigation--history)
          (cl-letf (((symbol-function 'ox-workspace-current-perspective) (lambda () 'P))
                    ((symbol-function 'ox-workspace-id) (lambda (&rest _) "A"))
                    ((symbol-function 'safe-persp-buffers)
                     (lambda (_) (list terminal editing)))
                    ((symbol-function 'window-prev-buffers)
                     (lambda (&optional _)
                       (with-current-buffer editing
                         (list (list editing (copy-marker 1)
                                     (copy-marker 1)))))))
            (switch-to-buffer terminal)
            (ox-buffer-navigation-switch-to-editing-buffer)
            (should (eq (current-buffer) editing))
            (should (equal (gethash "A" ox-buffer-navigation--history)
                           (list editing)))))
      (when (buffer-live-p terminal)
        (with-current-buffer terminal (setq ox-terminal-managed-p nil))
        (kill-buffer terminal))
      (when (buffer-live-p editing) (kill-buffer editing)))))

(ert-deftest ox-terminal-modules-are-reload-safe ()
  (load "ox-terminal" nil 'nomessage)
  (load "ox-buffer-navigation" nil 'nomessage)
  (load "ox-terminal" nil 'nomessage)
  (load "ox-buffer-navigation" nil 'nomessage)
  (should (= (cl-count #'ox-terminal--after-load-setup
                       after-load-functions :test #'eq)
             1))
  (should (= (cl-count #'ox-buffer-navigation-track-selected-buffer
                       window-selection-change-functions :test #'eq)
             1))
  (should (= (cl-count ox-terminal-count-modeline-format
                       mode-line-misc-info :test #'equal)
             1)))

(ert-deftest ox-terminal-modeline-removes-legacy-and-current-duplicates ()
  (let* ((original mode-line-misc-info)
         (legacy
          '(:eval
            (when (fboundp 'my/persp-vterm-buffer-count)
              (my/persp-vterm-buffer-count)))))
    (unwind-protect
        (progn
          (setq mode-line-misc-info
                (append mode-line-misc-info
                        (list legacy
                              ox-terminal-count-modeline-format
                              (copy-tree ox-terminal-count-modeline-format))))
          (ox-terminal-install-modeline)
          (should (= (cl-count-if #'ox-terminal--count-modeline-entry-p
                                  mode-line-misc-info)
                     1))
          (should-not (member legacy mode-line-misc-info)))
      (setq mode-line-misc-info original)
      (ox-terminal-install-modeline))))

(ert-deftest ox-buffer-navigation-switch-makes-terminal-window-alternate ()
  (let ((terminal (generate-new-buffer " *alternate-terminal*"))
        (editing (generate-new-buffer "alternate-editing")))
    (unwind-protect
        (progn
          (with-current-buffer terminal
            (setq-local ox-terminal-managed-p t
                        ox-terminal-owner-id "A"
                        ox-terminal-created-sequence 1
                        ox-terminal-backend 'ghostel))
          (puthash "A" (list editing) ox-buffer-navigation--history)
          (switch-to-buffer terminal)
          (set-window-prev-buffers (selected-window) nil)
          (cl-letf (((symbol-function 'ox-workspace-current-perspective) (lambda () 'P))
                    ((symbol-function 'ox-workspace-id) (lambda (&rest _) "A"))
                    ((symbol-function 'safe-persp-buffers)
                     (lambda (_) (list terminal editing))))
            (ox-buffer-navigation-switch-to-editing-buffer)
            (should (eq (current-buffer) editing))
            (should (memq terminal
                          (mapcar #'car
                                  (window-prev-buffers (selected-window)))))))
      (when (buffer-live-p terminal)
        (with-current-buffer terminal (setq ox-terminal-managed-p nil))
        (kill-buffer terminal))
      (when (buffer-live-p editing) (kill-buffer editing)))))

(provide 'ox-terminal-test)
;;; ox-terminal-test.el ends here
