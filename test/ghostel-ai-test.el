;;; ghostel-ai-test.el --- Tests for ghostel-ai -*- lexical-binding: t; -*-

;;; Commentary:

;; Offline tests: the line-mode input region is faked in a temp buffer
;; and no classifier or model is contacted.

;;; Code:

(require 'ert)
(require 'ghostel-ai)

(defun ghostel-ai-test--with-input (body)
  "Call BODY in a buffer whose line-mode input is \"git st\" at 16..22."
  (with-temp-buffer
    (insert "$ ls\nfoo bar\n$ git st")
    (setq-local ghostel--input-mode 'line
                ghostel--line-input-start (copy-marker 16)
                ghostel--line-input-end (copy-marker (point-max) t)
                ghostel--line-mode-history '("git status" "git st" "ls")
                ghostel-ai--shell-history '("git stash" "make" "git status"))
    (cl-letf (((symbol-function 'ghostel-command-running-p) #'ignore)
              ((symbol-function 'ghostel-ai--shell-name) (lambda () "zsh")))
      (goto-char (point-max))
      (funcall body))))

(ert-deftest ghostel-ai-history-capf ()
  (ghostel-ai-test--with-input
   (lambda ()
     (should (equal (seq-take (ghostel-ai--history-capf) 3)
                    '(16 22 ("git status"))))
     (goto-char 18)
     (should-not (ghostel-ai--history-capf)))))

(ert-deftest ghostel-ai-route ()
  (should (equal (ghostel-ai--route "#  list big files")
                 '(translate . "list big files")))
  (should (equal (ghostel-ai--route " ls -la") '(shell . "")))
  (should-not (ghostel-ai--route "ls\nrm -rf /"))
  (should-not (ghostel-ai--route "Echo the current path"))
  (should-not (ghostel-ai--route "lsof"))
  (should-not (ghostel-ai--route "git status")))

(ert-deftest ghostel-ai-line-mode-send-routes ()
  (ghostel-ai-test--with-input
   (lambda ()
     (let (translated)
       (cl-letf (((symbol-function 'ghostel-ai--translate)
                  (lambda (input) (setq translated input)))
                 ((symbol-function 'ghostel-ai--classify)
                  (lambda (_) (ert-fail "classified a routed line"))))
         (should (ghostel-ai--line-mode-send "# list big files"))
         (should (equal translated "list big files"))
         (should-not (ghostel-ai--line-mode-send "#"))
         (should-not (ghostel-ai--line-mode-send "ls -la"))
         (let ((current-prefix-arg '(4)))
           (should-not (ghostel-ai--line-mode-send "list big files"))))))))

(ert-deftest ghostel-ai-prompt ()
  (ghostel-ai-test--with-input
   (lambda ()
     (should (equal (ghostel-ai--prompt "%s on %o") "zsh on darwin"))
     (should (string-prefix-p "Is the input a literal zsh command line"
                              (ghostel-ai--prompt ghostel-ai-shell-question))))))

(ert-deftest ghostel-ai-completion-prompt ()
  (ghostel-ai-test--with-input
   (lambda ()
     (let ((p (ghostel-ai--completion-prompt "git st" 16)))
       (should (string-search "Shell: zsh on darwin" p))
       (should (string-search "Files: " p))
       (should (string-search "$ ls\nfoo bar\n$ \nRecent history:\ngit status\ngit st\nls\ngit stash\nmake" p))
       (should (string-search "Related history:\ngit status\ngit st\ngit stash\nInput: git st" p))))))

(ert-deftest ghostel-ai-llm-capf-uses-cache ()
  (ghostel-ai-test--with-input
   (lambda ()
     (setq ghostel-ai--completions '(("git st" . "atus --short")))
     (should (equal (nth 2 (ghostel-ai--llm-capf)) '("git status --short")))
     (setq ghostel-ai--completions '(("git st" . "")))
     (should-not (ghostel-ai--llm-capf))
     (setq ghostel-ai--completions '(("git st" . "atus"))
           ghostel-ai--pending t)
     (should-not (ghostel-ai--llm-capf))
     (setq ghostel-ai--pending nil)
     (cl-letf (((symbol-function 'ghostel-ai--llm-suffix)
                (lambda (&rest _) (ert-fail "asked the model"))))
       (dolist (input '("  " "# list"))
         (delete-region 16 (point-max))
         (insert input)
         (should-not (ghostel-ai--llm-capf)))))))

(ert-deftest ghostel-ai-llm-capf-stale-bounds ()
  (ghostel-ai-test--with-input
   (lambda ()
     (cl-letf (((symbol-function 'ghostel-ai--llm-suffix)
                (lambda (&rest _)
                  (save-excursion (goto-char 1) (insert "out\n"))
                  "atus")))
       (should-not (ghostel-ai--llm-capf))))))

(ert-deftest ghostel-ai-llm-suffix-caches-strings-only ()
  (ghostel-ai-test--with-input
   (lambda ()
     (let (cb)
       (cl-letf (((symbol-function 'ghostel-ai--gptel-request)
                  (lambda (_prompt _system callback) (setq cb callback)))
                 ((symbol-function 'ghostel-ai--await)
                  (lambda (start) (funcall start #'ignore))))
         (ghostel-ai--llm-suffix "git st" 16)
         (funcall cb nil nil)
         (should-not ghostel-ai--completions)
         (funcall cb "NONE" nil)
         (should (equal ghostel-ai--completions '(("git st" . ""))))
         (funcall cb " `NONE`.\n" nil)
         (should (equal (car ghostel-ai--completions) '("git st" . "")))
         (funcall cb "NONEXISTENT" nil)
         (should (equal (car ghostel-ai--completions) '("git st" . "NONEXISTENT"))))))))

(ert-deftest ghostel-ai-await ()
  (should (equal (ghostel-ai--await
                  (lambda (done) (run-at-time 0.05 nil done "x")))
                 "x"))
  (should (equal (ghostel-ai--await (lambda (done) (funcall done "y"))) "y"))
  (let ((ghostel-ai-completion-timeout 0.1))
    (should-not (ghostel-ai--await #'ignore))))

(ert-deftest ghostel-ai-await-quit ()
  (let (cb)
    (should (eq (condition-case nil
                    (ghostel-ai--await
                     (lambda (done)
                       (setq cb done)
                       (run-at-time 0.01 nil (lambda () (signal 'quit nil)))))
                  (quit 'quit))
                'quit))
    (funcall cb "late")
    (should-not unread-command-events)))

(ert-deftest ghostel-ai-await-cancel ()
  (unwind-protect
      (progn
        (should (eq (while-no-input
                      (ghostel-ai--await
                       (lambda (_done) (push ?a unread-command-events))))
                    t))
        (should (equal unread-command-events '((t . ?a)))))
    (setq unread-command-events nil)))

(ert-deftest ghostel-ai-clean ()
  (should (equal (ghostel-ai--clean "```sh\ngit status\n```\n") "git status"))
  (should (equal (ghostel-ai--clean "atus --short\n") "atus --short"))
  (should (equal (ghostel-ai--clean " status") " status"))
  (should (equal (ghostel-ai--clean "") "")))

(defun ghostel-ai-test--send (input answers)
  "Run the send hook on INPUT with the classifier returning ANSWERS.
Return (RESULT CLASSIFIED TRANSLATED)."
  (let (classified translated)
    (cl-letf (((symbol-function 'ghostel-ai--classify)
               (lambda (_) (setq classified t) answers))
              ((symbol-function 'ghostel-ai--translate)
               (lambda (_) (setq translated t)))
              ((symbol-function 'y-or-n-p) #'ignore))
      (list (ghostel-ai--line-mode-send input) classified translated))))

(ert-deftest ghostel-ai-line-mode-send ()
  (ghostel-ai-test--with-input
   (lambda ()
     (let ((shell '((is-shell . 0.9) (dangerous . 0.1)))
           (nl '((is-shell . 0.1) (dangerous . 0.1)))
           (danger '((is-shell . 0.9) (dangerous . 0.9))))
       (should (equal (ghostel-ai-test--send "  " shell) '(nil nil nil)))
       (should (equal (ghostel-ai-test--send "a\nb" shell) '(nil t nil)))
       (should (equal (ghostel-ai-test--send "ls -la" shell) '(nil nil nil)))
       (should (equal (ghostel-ai-test--send "git st" shell) '(nil t nil)))
       (should (equal (ghostel-ai-test--send "git st" nil) '(nil t nil)))
       (should (equal (ghostel-ai-test--send "list files" nl) '(t t t)))
       (should (equal (ghostel-ai-test--send "rm -rf /" danger) '(t t nil)))
       (setq ghostel--input-mode 'char)
       (should (equal (ghostel-ai-test--send "git st" nil) '(t t nil)))
       (setq ghostel--input-mode 'line
             ghostel-ai--pending t)
       (should (equal (ghostel-ai-test--send "git st" shell) '(t nil nil)))))))

(ert-deftest ghostel-ai-handle-translation ()
  (ghostel-ai-test--with-input
   (lambda ()
     (cl-flet ((handle (response)
                 (setq ghostel-ai--pending t)
                 (let (replaced)
                   (cl-letf (((symbol-function 'ghostel--line-mode-replace-input)
                              (lambda (c) (setq replaced c)))
                             ((symbol-function 'ghostel-line-mode-send-input)
                              (lambda (_) (ert-fail "sent input to the shell"))))
                     (ghostel-ai--handle-translation response nil))
                   (list replaced ghostel-ai--pending))))
       (should (equal (handle "```\n ls -la \n```") '("ls -la" nil)))
       (should (equal (handle "echo 'a\nb'") '("echo 'a\nb'" nil)))
       (should (equal (handle '(reasoning . "x")) '(nil t)))
       (should (equal (handle 'abort) '(nil nil)))
       (should (equal (handle nil) '(nil nil)))
       (should (equal (handle "") '(nil nil)))))))

(ert-deftest ghostel-ai-translate-ignores-stale-reply ()
  (ghostel-ai-test--with-input
   (lambda ()
     (let (cb watchdog)
       (cl-letf (((symbol-function 'ghostel-ai--gptel-request)
                  (lambda (_prompt _system callback) (setq cb callback)))
                 ((symbol-function 'run-at-time)
                  (lambda (_time _repeat fn) (setq watchdog fn)))
                 ((symbol-function 'gptel-abort) #'ignore)
                 ((symbol-function 'ghostel--line-mode-replace-input)
                  (lambda (_) (ert-fail "stale reply replaced input"))))
         (ghostel-ai--translate "list files")
         (ghostel-ai-mode -1)
         (funcall cb "ls" nil)
         (ghostel-ai--translate "list files")
         (funcall watchdog)
         (should-not ghostel-ai--pending)
         (funcall cb "ls" nil))))))

(defun ghostel-ai-test--classify (body)
  "Run `ghostel-ai--classify' with `url-retrieve' answering BODY.
Return (ANSWERS REQUEST-DATA AUTH-HEADER)."
  (let (data auth)
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (_url cb &rest _)
                 (setq data url-request-data
                       auth (cdr (assoc "Authorization" url-request-extra-headers)))
                 (with-current-buffer (generate-new-buffer " ghostel-ai-test")
                   (insert body)
                   (setq-local url-http-response-status 200
                               url-http-end-of-headers 1)
                   (funcall cb nil)
                   (current-buffer)))))
      (list (ghostel-ai--classify "git st") data auth))))

(ert-deftest ghostel-ai-classify ()
  (ghostel-ai-test--with-input
   (lambda ()
     (let ((ghostel-ai-typesafe-api-key "k")
           (inhibit-message t))
       (pcase-let ((`(,answers ,data ,auth)
                    (ghostel-ai-test--classify
                     "{\"answers\":{\"is_shell\":{\"type\":\"noul\",\"noul\":0.9},\"dangerous\":{\"type\":\"noul\",\"noul\":0.1}}}")))
         (should (equal answers '((is-shell . 0.9) (dangerous . 0.1))))
         (should (equal auth "Bearer k"))
         (let ((req (json-parse-string data :object-type 'alist)))
           (should (equal (alist-get 'input (alist-get 'state req)) "git st"))
           (should (string-search "zsh" (alist-get 'instructions (alist-get 'is_shell (alist-get 'questions req)))))))
       (should-not (car (ghostel-ai-test--classify "{\"answers\":{}}")))
       (should-not (car (ghostel-ai-test--classify "not json")))
       (let ((ghostel-ai-typesafe-api-key nil)
             (process-environment '("TYPESAFE_API_KEY")))
         (should-not (car (ghostel-ai-test--classify "{}"))))))))

(ert-deftest ghostel-ai-classify-timeout ()
  (let ((ghostel-ai-typesafe-api-key "k")
        (ghostel-ai-typesafe-timeout 0.2)
        (inhibit-message t)
        buf proc)
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (&rest _)
                 (setq buf (generate-new-buffer " ghostel-ai-test")
                       proc (start-process "ghostel-ai-test" buf "sleep" "10"))
                 (set-process-query-on-exit-flag proc t)
                 (set-process-sentinel
                  proc (lambda (&rest _) (ert-fail "url-http sentinel ran")))
                 buf)))
      (should-not (ghostel-ai--classify "git st"))
      (should-not (buffer-live-p buf))
      (should-not (process-live-p proc)))))

(ert-deftest ghostel-ai-mode-toggle ()
  (with-temp-buffer
    (let ((ghostel-ai-typesafe-api-key "k"))
      (ghostel-ai-mode 1)
      (should (memq #'ghostel-ai--history-capf completion-at-point-functions))
      (should (memq #'ghostel-ai--line-mode-send ghostel-line-mode-send-functions))
      (should completion-preview-mode)
      (should (eq completion-preview-active-mode-map ghostel-ai--preview-map))
      (ghostel-ai-mode -1)
      (should-not (memq #'ghostel-ai--llm-capf completion-at-point-functions))
      (should-not (memq #'ghostel-ai--line-mode-send ghostel-line-mode-send-functions))
      (should-not completion-preview-mode)
      (should-not (local-variable-p 'completion-preview-commands))
      (cl-letf (((default-value 'completion-preview-commands) t))
        (ghostel-ai-mode 1)
        (should (eq completion-preview-commands t))
        (ghostel-ai-mode -1)))))

(provide 'ghostel-ai-test)
;;; ghostel-ai-test.el ends here
