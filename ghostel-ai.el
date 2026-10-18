;;; ghostel-ai.el --- Natural-language commands for ghostel line mode -*- lexical-binding: t; -*-

;; Copyright (c) 2026 Daniel Kraus <daniel@kraus.my>

;; Author: Daniel Kraus <daniel@kraus.my>
;; URL: https://github.com/dakra/ghostel-ai
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (gptel "0.9.9") (ghostel "0.57.0"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; `ghostel-ai-mode' intercepts RET in `ghostel-line-mode' at a shell
;; prompt.  TypeSafe's Jev classifier decides whether the input is a
;; shell command or an instruction in natural language, and whether it
;; is destructive.  Instructions are translated into a command by gptel
;; and put back into the input region for review; destructive commands
;; ask for confirmation before they are sent.
;;
;; While typing, `completion-preview-mode' shows a suggestion after
;; point: a shell-history entry starting with the input when there is
;; one, otherwise a continuation from gptel.  TAB accepts it.  The
;; model receives the shell name, directory listing, the last lines of
;; terminal output and matching history entries.
;;
;; Needs a TypeSafe API key in `ghostel-ai-typesafe-api-key' or the
;; TYPESAFE_API_KEY environment variable, and a configured gptel.
;;
;;   (add-hook 'ghostel-mode-hook #'ghostel-ai-mode)

;;; Code:

(require 'ghostel)
(require 'ghostel-line-mode)
(require 'gptel)
(require 'url-http)
(require 'completion-preview)
(require 'format-spec)

(defvar url-http-end-of-headers)
(defvar url-http-response-status)

(defgroup ghostel-ai nil
  "Natural-language commands for ghostel line mode."
  :group 'ghostel
  :prefix "ghostel-ai-")

(defcustom ghostel-ai-typesafe-api-key nil
  "TypeSafe API key, or a function of no arguments returning it.
Nil reads the TYPESAFE_API_KEY environment variable."
  :type '(choice (const :tag "From environment" nil) string function))

(defcustom ghostel-ai-typesafe-timeout 2
  "Seconds to wait for the classifier before sending the input as-is."
  :type 'number)

(defcustom ghostel-ai-routes
  '(("\\`\\s-*#" . translate)
    ("\\`\\s-*\\(?:cd\\|ls\\|pwd\\|cat\\|less\\|echo\\|clear\\|exit\\)\\b[^\n]*\\'" . shell))
  "Where line-mode input goes before the classifier sees it.
Each element is (REGEXP . ROUTE); the first REGEXP matching the input
wins and unmatched input is classified.  ROUTE `shell' sends the input
as typed, `translate' sends the input minus the matched text to gptel,
`classify' asks Jev."
  :type '(alist :key-type regexp
                :value-type (choice (const shell) (const translate)
                                    (const classify))))

(defcustom ghostel-ai-shell-threshold 0.5
  "Below this probability of being a shell command, input is translated."
  :type 'number)

(defcustom ghostel-ai-danger-threshold 0.5
  "Above this probability of being destructive, a command asks first."
  :type 'number)

(defcustom ghostel-ai-gptel-backend nil
  "Gptel backend used for translation.  Nil uses `gptel-backend'."
  :type '(choice (const :tag "Default" nil) sexp))

(defcustom ghostel-ai-gptel-model nil
  "Gptel model used for translation.  Nil uses `gptel-model'."
  :type '(choice (const :tag "Default" nil) symbol))

(defcustom ghostel-ai-translate-timeout 30
  "Seconds to wait for a translation before the request is aborted."
  :type 'number)

(defcustom ghostel-ai-completion-delay 0.5
  "Idle seconds before a completion is suggested."
  :type 'number)

(defcustom ghostel-ai-completion-timeout 10
  "Seconds to wait for the model before giving up on a completion."
  :type 'number)

(defcustom ghostel-ai-shell-question
  "Is the input a literal %s command line, as opposed to an instruction or question written in natural language?"
  "Jev question deciding whether the input is a shell command.
`format-spec' sequences: %s shell name, %o operating system, %d directory."
  :type 'string)

(defcustom ghostel-ai-danger-question
  "Would running the input in %s destroy or irreversibly change data, e.g. delete files, force-push, drop tables, overwrite disks or reset history?"
  "Jev question deciding whether the input is destructive.
`format-spec' sequences: %s shell name, %o operating system, %d directory."
  :type 'string)

(defcustom ghostel-ai-translate-prompt
  "Translate the user's instruction into one %s command line to run on %o in %d.  Prefer portable, non-interactive commands.  Reply with only the command line, no explanation and no code fences."
  "System prompt for translating natural language into a command.
`format-spec' sequences: %s shell name, %o operating system, %d directory."
  :type 'string)

(defcustom ghostel-ai-completion-prompt
  "You autocomplete %s command lines like an IDE.  Reply with only the text to append after the input so that input plus your reply is one complete, correct %s command line.  Never repeat the input, add no explanation and no code fences.  Reply with NONE when nothing useful can be added."
  "System prompt for ghost-text completion.
`format-spec' sequences: %s shell name, %o operating system, %d directory."
  :type 'string)

(defvar-local ghostel-ai--pending nil
  "Token of the translation request in flight, or nil.")

(defvar-local ghostel-ai--shell-history 'unfetched
  "Cached `ghostel-shell-history', or nil when unavailable.")

(defvar-local ghostel-ai--completions nil
  "Alist of (INPUT . SUFFIX) answers from the model, newest first.")

(defvar-keymap ghostel-ai--preview-map
  :doc "Buffer-local `completion-preview-active-mode-map' that also binds <tab>.
Line mode binds <tab> itself, which would shadow the parent map's C-i."
  :parent completion-preview-active-mode-map
  "<tab>" #'completion-preview-insert)

(defun ghostel-ai--shell-name ()
  "Return the running shell's name, e.g. \"zsh\"."
  (file-name-nondirectory (or ghostel--shell-comm ghostel--shell-program "")))

(defun ghostel-ai--prompt (template)
  "Expand %s, %o and %d in TEMPLATE to the shell, OS and directory."
  (format-spec template `((?s . ,(ghostel-ai--shell-name))
                          (?o . ,(symbol-name system-type))
                          (?d . ,(abbreviate-file-name default-directory)))))

(defun ghostel-ai--api-key ()
  "Return the TypeSafe API key, or nil."
  (cond ((functionp ghostel-ai-typesafe-api-key)
         (funcall ghostel-ai-typesafe-api-key))
        (ghostel-ai-typesafe-api-key)
        (t (let ((process-environment (default-value 'process-environment)))
             (getenv "TYPESAFE_API_KEY")))))

(defun ghostel-ai--retrieve (url timeout)
  "Fetch URL and return its buffer, or signal after TIMEOUT seconds.
Unlike `url-retrieve-synchronously', closes the connection on timeout."
  (let* ((status 'pending)
         (buf (or (url-retrieve url (lambda (s) (setq status s)) nil t t)
                  (error "No retrieval buffer")))
         (deadline (time-add nil timeout)))
    (while (and (eq status 'pending) (time-less-p nil deadline))
      (accept-process-output nil 0.1))
    (when (eq status 'pending)
      (when-let* ((proc (get-buffer-process buf)))
        ;; url-http's own sentinel would retry the request.
        (set-process-sentinel proc #'ignore)
        (delete-process proc))
      (let (kill-buffer-query-functions) (kill-buffer buf))
      (error "Timeout"))
    buf))

(defun ghostel-ai--route (input)
  "Return (ROUTE . REST) for INPUT from `ghostel-ai-routes', or nil.
REST is INPUT without the matched text, trimmed.  Matching is case-sensitive."
  (let ((case-fold-search nil))
    (seq-some (lambda (route)
                (when (string-match (car route) input)
                  (cons (cdr route) (string-trim (replace-match "" t t input)))))
              ghostel-ai-routes)))

(defun ghostel-ai--cancel ()
  "Drop the pending translation so its reply is ignored."
  (when ghostel-ai--pending
    (setq ghostel-ai--pending nil)
    (let ((inhibit-message t)) (gptel-abort (current-buffer)))))

(defun ghostel-ai--classify (input)
  "Ask Jev about INPUT; return an alist with `is-shell' and `dangerous'.
Both values are probabilities.  Return nil when the request fails."
  (when-let* ((key (ghostel-ai--api-key)))
    (let ((url-request-method "POST")
          (url-request-extra-headers
           `(("Content-Type" . "application/json")
             ("Authorization" . ,(concat "Bearer " key))))
          (url-request-data
           (json-serialize
            `((model . "jev-latest")
              (state . ((input . ,input)
                        (shell . ,(ghostel-ai--shell-name))
                        (cwd . ,(abbreviate-file-name default-directory))
                        (os . ,(symbol-name system-type))))
              (questions
               . ((is_shell
                   . ((type . "noul")
                      (instructions
                       . ,(ghostel-ai--prompt ghostel-ai-shell-question))))
                  (dangerous
                   . ((type . "noul")
                      (instructions
                       . ,(ghostel-ai--prompt ghostel-ai-danger-question))))))))))
      (condition-case err
          (let ((buf (ghostel-ai--retrieve "https://api.typesafe.ai/v1/systemone"
                                           ghostel-ai-typesafe-timeout)))
            (unwind-protect
                (with-current-buffer buf
                  (unless (eq url-http-response-status 200)
                    (error "HTTP %s" url-http-response-status))
                  (goto-char url-http-end-of-headers)
                  (let* ((answers (alist-get 'answers
                                             (json-parse-buffer :object-type 'alist)))
                         (is-shell (alist-get 'noul (alist-get 'is_shell answers)))
                         (dangerous (alist-get 'noul (alist-get 'dangerous answers))))
                    (unless (and (numberp is-shell) (numberp dangerous))
                      (error "Unexpected response"))
                    `((is-shell . ,is-shell) (dangerous . ,dangerous))))
              (kill-buffer buf)))
        (error (message "ghostel-ai: classifier unavailable (%s)"
                        (error-message-string err))
               nil)))))

(defun ghostel-ai--clean (response)
  "Return RESPONSE without code fences and trailing whitespace."
  (string-trim-right
   (replace-regexp-in-string "\\`[ \t\n]*```[^\n]*\n\\|\n?```[ \t\n]*\\'" ""
                             response)))

(defun ghostel-ai--gptel-request (prompt system callback)
  "Send PROMPT with SYSTEM message to gptel, calling CALLBACK with the reply."
  (let ((gptel-backend (or ghostel-ai-gptel-backend gptel-backend))
        (gptel-model (or ghostel-ai-gptel-model gptel-model))
        (gptel-use-tools nil)
        (gptel-use-context nil))
    (gptel-request prompt :system system :callback callback)))

(defun ghostel-ai--translate (input)
  "Ask gptel to turn INPUT into a shell command and put it in the input region.
On failure INPUT stays in the input region."
  (let ((token (list input))
        (buf (current-buffer)))
    (setq ghostel-ai--pending token)
    (message "ghostel-ai: translating…")
    (condition-case err
        (progn
          (ghostel-ai--gptel-request
           input
           (ghostel-ai--prompt ghostel-ai-translate-prompt)
           (lambda (response info)
             (when (buffer-live-p buf)
               (with-current-buffer buf
                 (when (eq ghostel-ai--pending token)
                   (ghostel-ai--handle-translation response info))))))
          ;; gptel never calls back on a blank reply, so the watchdog
          ;; clears the token itself rather than relying on `gptel-abort'.
          (run-at-time ghostel-ai-translate-timeout nil
                       (lambda ()
                         (when (and (buffer-live-p buf)
                                    (eq (buffer-local-value 'ghostel-ai--pending buf)
                                        token))
                           (with-current-buffer buf
                             (ghostel-ai--cancel)
                             (message "ghostel-ai: translation timed out"))))))
      (error
       (setq ghostel-ai--pending nil)
       (message "ghostel-ai: gptel failed (%s), input kept"
                (error-message-string err))))))

(defun ghostel-ai--handle-translation (response info)
  "Put the command in RESPONSE into the input region.
Reasoning arrives as a cons and is ignored.  `abort', an empty reply,
nil or another symbol (a failed request, INFO carries its status) all
leave the input in place."
  (let ((command (and (stringp response)
                      (string-trim (ghostel-ai--clean response)))))
    (unless (consp response) (setq ghostel-ai--pending nil))
    (cond
     ((consp response))
     ((eq response 'abort)
      (message "ghostel-ai: translation aborted"))
     ((not (eq ghostel--input-mode 'line))
      (message "ghostel-ai: %s" (or command response)))
     ((and command (not (string-empty-p command)))
      (ghostel--line-mode-replace-input command)
      (message "ghostel-ai: review and press RET"))
     (command
      (message "ghostel-ai: empty reply, input kept"))
     (t
      (message "ghostel-ai: translation failed (%s), input kept"
               (or (plist-get info :status) response))))))

(defun ghostel-ai--line-mode-send (input)
  "Classify INPUT before `ghostel-line-mode-send' ships it.
Return non-nil to keep the input in the buffer instead of sending it."
  (cond
   (current-prefix-arg (ghostel-ai--cancel) nil)
   (ghostel-ai--pending
    (message "ghostel-ai: still translating, C-u RET sends as typed")
    t)
   ((or (string-blank-p input)
        (ghostel-command-running-p))
    nil)
   (t
    (pcase (ghostel-ai--route input)
      (`(shell . ,_) nil)
      (`(translate . ,rest)
       (unless (string-empty-p rest)
         (ghostel-ai--translate rest)
         t))
      (_
       (let ((answers (ghostel-ai--classify input)))
         (cond
          ;; PTY output during the classifier wait may have torn line mode down.
          ((not (eq ghostel--input-mode 'line)) t)
          ((null answers) nil)
          ((< (alist-get 'is-shell answers) ghostel-ai-shell-threshold)
           (ghostel-ai--translate input)
           t)
          ((> (alist-get 'dangerous answers) ghostel-ai-danger-threshold)
           (not (y-or-n-p "Looks destructive.  Run anyway? "))))))))))

;;;###autoload
(defun ghostel-ai-send-to-shell ()
  "Send the line-mode input as typed, skipping classifier and translation."
  (interactive)
  (unless (eq ghostel--input-mode 'line)
    (user-error "Not in line mode"))
  (ghostel-ai--cancel)
  (ghostel-line-mode-send-input (ghostel--line-mode-input-text)))

;;;; Completion

(defun ghostel-ai--await (start)
  "Call START with a callback and block until the callback runs.
Return the callback's argument.  A keypress while waiting is put back
on the event queue and aborts an enclosing `while-no-input'; a timeout
returns nil."
  (let ((result 'ghostel-ai--waiting)
        (toi throw-on-input)
        (throw-on-input nil))
    (funcall start (lambda (value)
                     (when (eq result 'ghostel-ai--waiting)
                       (setq result value)
                       (push 'ghostel-ai--done unread-command-events))))
    (unwind-protect
        (while (eq result 'ghostel-ai--waiting)
          (let ((ev (let ((input-method-function nil) (echo-keystrokes 0))
                      (read-event nil nil ghostel-ai-completion-timeout))))
            (cond
             ((eq ev 'ghostel-ai--done))
             ((null ev) (setq result nil))
             (t (push (cons t ev) unread-command-events)
                (setq result nil)
                (when toi (throw toi t))))))
      ;; A quit leaves RESULT waiting; stop the late callback's push.
      (when (eq result 'ghostel-ai--waiting) (setq result nil))
      (setq unread-command-events
            (delq 'ghostel-ai--done unread-command-events)))
    result))

(defun ghostel-ai--input-bounds ()
  "Return (BEG . END) of the line-mode input when point is at its end."
  (when-let* (((eq ghostel--input-mode 'line))
              ((markerp ghostel--line-input-start))
              (beg (marker-position ghostel--line-input-start))
              (end (marker-position ghostel--line-input-end))
              ((< beg end))
              ((= end (point)))
              ((not (ghostel-command-running-p))))
    (cons beg end)))

(defun ghostel-ai--history ()
  "Return this buffer's history, newest first, session entries first."
  (when (eq ghostel-ai--shell-history 'unfetched)
    (setq ghostel-ai--shell-history
          (condition-case nil (ghostel-shell-history) (error nil))))
  (delete-dups (append ghostel--line-mode-history ghostel-ai--shell-history nil)))

(defun ghostel-ai--history-capf ()
  "Complete the input with the newest history entry that starts with it."
  (when-let* ((bounds (ghostel-ai--input-bounds))
              (input (buffer-substring-no-properties (car bounds) (cdr bounds)))
              (cand (seq-find (lambda (e) (and (string-prefix-p input e)
                                               (not (string= input e))))
                              (ghostel-ai--history))))
    (list (car bounds) (cdr bounds) (list cand) :exclusive 'no)))

(defun ghostel-ai--completion-prompt (input beg)
  "Build the completion prompt for INPUT, whose region starts at BEG."
  (let* ((word (car (split-string input)))
         (history (ghostel-ai--history))
         (related (seq-take (seq-filter (lambda (e) (string-prefix-p word e))
                                        history)
                            20))
         (output (buffer-substring-no-properties
                  (save-excursion (goto-char beg) (forward-line -30) (point))
                  beg)))
    (concat
     (format "Shell: %s on %s\nDirectory: %s\n"
             (ghostel-ai--shell-name) system-type
             (abbreviate-file-name default-directory))
     (unless (file-remote-p default-directory)
       (format "Files: %s\n"
               (string-join (directory-files default-directory nil
                                             directory-files-no-dot-files-regexp
                                             nil 50)
                            " ")))
     "Recent terminal output:\n"
     (replace-regexp-in-string "[ \t]+\n" "\n" output)
     "\nRecent history:\n" (string-join (seq-take history 10) "\n")
     "\nRelated history:\n" (string-join related "\n")
     "\nInput: " input)))

(defun ghostel-ai--llm-suffix (input beg)
  "Return the model's continuation of INPUT, or nil.
BEG is the start of the input region.  Answers are cached per INPUT;
a cancelled wait still fills the cache when the reply arrives."
  (if-let* ((hit (assoc input ghostel-ai--completions)))
      (cdr hit)
    (let ((buf (current-buffer)))
      (ghostel-ai--await
       (lambda (done)
         (ghostel-ai--gptel-request
          (ghostel-ai--completion-prompt input beg)
          (ghostel-ai--prompt ghostel-ai-completion-prompt)
          (lambda (response _info)
            (unless (consp response)
              (let ((suffix (and (stringp response)
                                 (ghostel-ai--clean response))))
                (when (and suffix (string-match-p "\\`[ `*]*NONE[`*.]*\\'" suffix))
                  (setq suffix ""))
                (when (and suffix (buffer-live-p buf))
                  (with-current-buffer buf
                    (setq ghostel-ai--completions
                          (ntake 20 (cons (cons input suffix)
                                          ghostel-ai--completions)))))
                (funcall done suffix))))))))))

(defun ghostel-ai--llm-capf ()
  "Complete the input with a continuation from the model."
  (when-let* (((not ghostel-ai--pending))
              (bounds (ghostel-ai--input-bounds))
              (input (buffer-substring-no-properties (car bounds) (cdr bounds)))
              ((not (string-blank-p input)))
              ((not (string-search "\n" input)))
              ((not (eq (car (ghostel-ai--route input)) 'translate)))
              (suffix (with-demoted-errors "ghostel-ai: %S"
                        (ghostel-ai--llm-suffix input (car bounds))))
              ((not (string-empty-p suffix)))
              ;; Terminal output during the wait moves the input region.
              ((equal (ghostel-ai--input-bounds) bounds)))
    (list (car bounds) (cdr bounds) (list (concat input suffix))
          :exclusive 'no)))

;;;; Mode

;;;###autoload
(define-minor-mode ghostel-ai-mode
  "Classify and translate line-mode input, and suggest completions."
  :lighter " AI"
  (setq ghostel-ai--pending nil
        ghostel-ai--shell-history 'unfetched
        ghostel-ai--completions nil)

  (if ghostel-ai-mode
      (progn
        (unless (ghostel-ai--api-key)
          (message "ghostel-ai: no TypeSafe API key, input is not classified"))
        (add-hook 'ghostel-line-mode-send-functions
                  #'ghostel-ai--line-mode-send nil t)
        (add-hook 'completion-at-point-functions #'ghostel-ai--llm-capf -10 t)
        (add-hook 'completion-at-point-functions #'ghostel-ai--history-capf -20 t)
        (setq-local completion-preview-minimum-symbol-length nil
                    completion-preview-idle-delay ghostel-ai-completion-delay
                    completion-preview-commands
                    (or (eq completion-preview-commands t)
                        (cons 'ghostel-line-mode-self-insert
                              completion-preview-commands)))
        (setq-local completion-preview-active-mode-map ghostel-ai--preview-map)
        (completion-preview-mode 1))

    (remove-hook 'ghostel-line-mode-send-functions
                 #'ghostel-ai--line-mode-send t)
    (remove-hook 'completion-at-point-functions #'ghostel-ai--llm-capf t)
    (remove-hook 'completion-at-point-functions #'ghostel-ai--history-capf t)
    (kill-local-variable 'completion-preview-minimum-symbol-length)
    (kill-local-variable 'completion-preview-idle-delay)
    (kill-local-variable 'completion-preview-commands)
    (kill-local-variable 'completion-preview-active-mode-map)
    (completion-preview-mode -1)))

(provide 'ghostel-ai)
;;; ghostel-ai.el ends here
