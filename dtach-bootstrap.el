;;; dtach-bootstrap.el --- Bootstrap dtach for local and TRAMP targets -*- lexical-binding: t; -*-

;; Author: dcol
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: processes, terminals, tramp
;; URL: https://github.com/YOU/dtach-bootstrap

;;; Commentary:

;; Ensure a Linux x86_64 dtach executable exists on the current local or
;; TRAMP target, returning the target-local executable path for callers such
;; as detached.el.

;;; Code:

(require 'cl-lib)
(require 'files-x)
(require 'subr-x)
(require 'tramp)

(defgroup dtach-bootstrap nil
  "Bootstrap dtach on local and TRAMP targets."
  :group 'processes
  :prefix "dtach-bootstrap-")

(defcustom dtach-bootstrap-install-directory
  "~/.cache/dtach-bootstrap/bin"
  "Target-local directory where bootstrapped dtach is installed."
  :type 'directory)

(defcustom dtach-bootstrap-install-strategies
  '(system cached nix)
  "Ordered strategies used by `dtach-bootstrap-ensure'.

`system' uses dtach already available on the target PATH.
`cached' uses a previously installed bootstrapped dtach.
`nix' builds dtach locally with Nix and copies it to the target."
  :type '(repeat (choice (const system)
                         (const cached)
                         (const nix))))

(defcustom dtach-bootstrap-nix-command
  "nix"
  "Local Nix executable used to build dtach."
  :type 'string)

(defcustom dtach-bootstrap-nix-extra-arguments
  '("--extra-experimental-features" "nix-command flakes")
  "Extra arguments passed to Nix before the `build' subcommand."
  :type '(repeat string))

(defcustom dtach-bootstrap-nix-flake-directory
  (when-let* ((library (or load-file-name
                           buffer-file-name
                           (locate-library "dtach-bootstrap"))))
    (file-name-directory library))
  "Local directory containing the dtach-bootstrap flake.

If this points at a subdirectory of the package, dtach-bootstrap searches
upward for `flake.nix'."
  :type '(choice (const :tag "Discover from dtach-bootstrap.el" nil)
                 directory))

(defcustom dtach-bootstrap-nix-package
  ".#dtach-x86_64-linux"
  "Nix flake package attribute used to build dtach."
  :type 'string)

(defcustom dtach-bootstrap-prefer-system-dtach
  t
  "When non-nil, keep `system' before `cached' in the default strategy order."
  :type 'boolean)

(defcustom dtach-bootstrap-verify-after-install
  t
  "When non-nil, smoke-test dtach before returning it."
  :type 'boolean)

(defcustom dtach-bootstrap-detached-missing-action
  'prompt
  "What detached integration does when `detached-dtach-program' is missing.

`prompt' asks whether to run `dtach-bootstrap-ensure'.
`bootstrap' runs `dtach-bootstrap-ensure' without asking.
`error' signals a clear error."
  :type '(choice (const prompt)
                 (const bootstrap)
                 (const error)))

(defcustom dtach-bootstrap-detached-session-directory
  "~/.cache/detached/sessions"
  "Remote session directory used for detached.el TRAMP sessions."
  :type 'directory)

(defcustom dtach-bootstrap-detached-connection-profile
  'dtach-bootstrap-detached
  "Connection-local profile name installed for detached.el TRAMP support."
  :type 'symbol)

(defcustom dtach-bootstrap-detached-tramp-criteria
  '((:application tramp :protocol "ssh"))
  "Connection-local criteria where detached.el remote defaults are installed."
  :type '(repeat sexp))

(defconst dtach-bootstrap--supported-system "Linux")
(defconst dtach-bootstrap--supported-architectures '("x86_64" "amd64"))

(defvar detached-dtach-program)
(defvar detached-session-directory)
(defvar dtach-bootstrap-detached-mode)

(declare-function detached-session-working-directory "detached" (session))

(defun dtach-bootstrap--directory (directory)
  "Return DIRECTORY or `default-directory' as a directory name."
  (file-name-as-directory (or directory default-directory)))

(defun dtach-bootstrap--remote-prefix (directory)
  "Return the TRAMP prefix for DIRECTORY, or nil for a local directory."
  (file-remote-p (dtach-bootstrap--directory directory)))

(defun dtach-bootstrap--target-local-file-name (file)
  "Return FILE as a target-local name.

For TRAMP names this strips the TRAMP prefix.  Local files are expanded."
  (if (file-remote-p file)
      (tramp-file-name-localname (tramp-dissect-file-name file))
    (expand-file-name file)))

(defun dtach-bootstrap--tramp-file-name (target-local-file directory)
  "Return an Emacs file name for TARGET-LOCAL-FILE on DIRECTORY's target."
  (if-let* ((prefix (dtach-bootstrap--remote-prefix directory)))
      (concat prefix target-local-file)
    target-local-file))

(defun dtach-bootstrap--target-default-directory (directory)
  "Return a usable `default-directory' for running commands on DIRECTORY's target."
  (dtach-bootstrap--directory directory))

(defun dtach-bootstrap--target-home-directory (directory)
  "Return DIRECTORY target's home directory as a target-local path."
  (if (dtach-bootstrap--remote-prefix directory)
      (car (dtach-bootstrap--target-lines
            directory "sh" "-lc" "printf '%s\n' \"$HOME\""))
    (expand-file-name "~")))

(defun dtach-bootstrap--target-local-directory (directory)
  "Return DIRECTORY as a target-local directory path."
  (let ((directory (dtach-bootstrap--directory directory)))
    (if (dtach-bootstrap--remote-prefix directory)
        (let ((localname (dtach-bootstrap--target-local-file-name directory)))
          (cond
           ((string= localname "~")
            (dtach-bootstrap--target-home-directory directory))
           ((string-prefix-p "~/" localname)
            (expand-file-name (substring localname 2)
                              (file-name-as-directory
                               (dtach-bootstrap--target-home-directory directory))))
           (t localname)))
      (expand-file-name directory))))

(defun dtach-bootstrap--target-local-expand-file-name (file directory)
  "Expand FILE as a target-local path for DIRECTORY's target."
  (cond
   ((string= file "~")
    (dtach-bootstrap--target-home-directory directory))
   ((string-prefix-p "~/" file)
    (expand-file-name (substring file 2)
                      (file-name-as-directory
                       (dtach-bootstrap--target-home-directory directory))))
   ((file-name-absolute-p file)
    (expand-file-name file))
   (t
    (expand-file-name file
                      (file-name-as-directory
                       (dtach-bootstrap--target-local-directory directory))))))

(defun dtach-bootstrap--install-directory-file-name (directory)
  "Return the Emacs file name for the target install directory."
  (file-name-as-directory
   (dtach-bootstrap--tramp-file-name
    (dtach-bootstrap--install-directory-target-name directory)
    directory)))

(defun dtach-bootstrap--install-directory-target-name (directory)
  "Return the target-local install directory for DIRECTORY."
  (directory-file-name
   (dtach-bootstrap--target-local-expand-file-name
    dtach-bootstrap-install-directory
    directory)))

(defun dtach-bootstrap--installed-file-name (directory)
  "Return the Emacs file name for bootstrapped dtach on DIRECTORY's target."
  (dtach-bootstrap--tramp-file-name
   (dtach-bootstrap--installed-target-name directory)
   directory))

(defun dtach-bootstrap--installed-target-name (directory)
  "Return the target-local path for bootstrapped dtach on DIRECTORY's target."
  (expand-file-name "dtach"
                    (file-name-as-directory
                     (dtach-bootstrap--install-directory-target-name directory))))

(defun dtach-bootstrap--call-target (directory program &rest args)
  "Run PROGRAM with ARGS on DIRECTORY's target.

Return a cons cell of the process exit status and trimmed output."
  (with-temp-buffer
    (let* ((default-directory (dtach-bootstrap--target-default-directory directory))
           (status (apply #'process-file program nil t nil args))
           (output (string-trim (buffer-string))))
      (cons status output))))

(defun dtach-bootstrap--target-lines (directory program &rest args)
  "Run PROGRAM with ARGS on DIRECTORY's target and return output lines.

Signal an error when the command fails."
  (pcase-let ((`(,status . ,output)
               (apply #'dtach-bootstrap--call-target directory program args)))
    (unless (equal status 0)
      (error "Target probe failed: %s %s exited with %S: %s"
             program (string-join args " ") status output))
    (split-string output "\n" t "[[:space:]\n]+")))

(defun dtach-bootstrap--normalize-architecture (architecture)
  "Normalize ARCHITECTURE for support checks."
  (downcase (string-trim architecture)))

(defun dtach-bootstrap--probe-target (directory)
  "Probe DIRECTORY's target and return plist with :system and :machine."
  (let* ((system (car (dtach-bootstrap--target-lines directory "uname" "-s")))
         (machine (car (dtach-bootstrap--target-lines directory "uname" "-m"))))
    (list :system system :machine machine)))

(defun dtach-bootstrap--ensure-supported-target (directory)
  "Signal unless DIRECTORY's target is supported."
  (let* ((probe (dtach-bootstrap--probe-target directory))
         (system (plist-get probe :system))
         (machine (dtach-bootstrap--normalize-architecture
                   (plist-get probe :machine))))
    (unless (string= system dtach-bootstrap--supported-system)
      (error "Unsupported target: expected Linux x86_64, got %s %s"
             system machine))
    (unless (member machine dtach-bootstrap--supported-architectures)
      (error "Unsupported target: expected Linux x86_64, got %s %s"
             system machine))
    probe))

(defun dtach-bootstrap--smoke-test (directory executable)
  "Verify EXECUTABLE runs on DIRECTORY's target."
  (pcase-let ((`(,status . ,output)
               (dtach-bootstrap--call-target directory executable "--help")))
    (unless (and (integerp status)
                 (not (member status '(126 127)))
                 (string-match-p "\\(?:dtach\\|usage\\|Usage\\)" output))
      (error "Remote smoke test failed: %s --help exited with %S: %s"
             executable status output)))
  executable)

(defun dtach-bootstrap--maybe-smoke-test (directory executable)
  "Smoke-test EXECUTABLE on DIRECTORY's target when configured."
  (when dtach-bootstrap-verify-after-install
    (dtach-bootstrap--smoke-test directory executable))
  executable)

(defun dtach-bootstrap--system-dtach (directory)
  "Return target-local system dtach path for DIRECTORY, or nil."
  (pcase-let ((`(,status . ,output)
               (dtach-bootstrap--call-target
                directory "sh" "-lc" "command -v dtach 2>/dev/null")))
    (when (and (equal status 0)
               (string-prefix-p "/" output))
      (dtach-bootstrap--maybe-smoke-test directory output))))

(defun dtach-bootstrap--cached-dtach (directory)
  "Return target-local cached dtach path for DIRECTORY, or nil."
  (let* ((file-name (dtach-bootstrap--installed-file-name directory))
         (target-name (dtach-bootstrap--installed-target-name directory)))
    (when (and (file-exists-p file-name)
               (file-executable-p file-name))
      (dtach-bootstrap--maybe-smoke-test directory target-name))))

(defun dtach-bootstrap--find-flake-directory (directory)
  "Return nearest ancestor of DIRECTORY containing flake.nix, or nil."
  (when directory
    (let ((directory (file-name-as-directory (expand-file-name directory)))
          found)
      (while (and directory (not found))
        (if (file-exists-p (expand-file-name "flake.nix" directory))
            (setq found directory)
          (let ((parent (file-name-directory (directory-file-name directory))))
            (setq directory
                  (unless (or (null parent) (string= parent directory))
                    parent)))))
      found)))

(defun dtach-bootstrap--resolve-flake-directory ()
  "Return the local flake directory, or signal a clear error."
  (let* ((candidate (or dtach-bootstrap-nix-flake-directory
                        (when-let* ((library (locate-library "dtach-bootstrap")))
                          (file-name-directory library))))
         (flake-directory (dtach-bootstrap--find-flake-directory candidate)))
    (unless flake-directory
      (error "Nix flake directory not found from %S: set `dtach-bootstrap-nix-flake-directory' to the dtach-bootstrap repo directory"
             candidate))
    flake-directory))

(defun dtach-bootstrap--nix-executable ()
  "Return the local Nix executable, or signal a clear error."
  (or (executable-find dtach-bootstrap-nix-command)
      (error "Nix not found locally: %s" dtach-bootstrap-nix-command)))

(defun dtach-bootstrap--nix-package-reference (flake-directory)
  "Return explicit Nix package reference for FLAKE-DIRECTORY."
  (if (string-prefix-p ".#" dtach-bootstrap-nix-package)
      (concat (directory-file-name (expand-file-name flake-directory))
              (substring dtach-bootstrap-nix-package 1))
    dtach-bootstrap-nix-package))

(defun dtach-bootstrap--nix-build ()
  "Build dtach with local Nix and return the store output path."
  (let ((flake-directory (dtach-bootstrap--resolve-flake-directory))
        (nix (dtach-bootstrap--nix-executable)))
    (with-temp-buffer
      (let* ((default-directory flake-directory)
             (arguments (append dtach-bootstrap-nix-extra-arguments
                                (list "build"
                                      (dtach-bootstrap--nix-package-reference
                                       flake-directory)
                                      "--print-out-paths"
                                      "--no-link")))
             (status (apply #'process-file nix nil t nil arguments)))
        (unless (equal status 0)
          (error "Nix build failed: %s" (string-trim (buffer-string))))
        (car (last (split-string (string-trim (buffer-string)) "\n" t)))))))

(defun dtach-bootstrap--nix-built-binary ()
  "Build dtach with Nix and return the local bin/dtach artifact."
  (let* ((output-path (dtach-bootstrap--nix-build))
         (binary (expand-file-name "bin/dtach" output-path)))
    (unless (file-exists-p binary)
      (error "Built artifact missing bin/dtach: %s" output-path))
    binary))

(defun dtach-bootstrap--ensure-target-cache-directory (directory)
  "Create and validate DIRECTORY's target cache directory."
  (let ((install-directory (dtach-bootstrap--install-directory-file-name directory)))
    (condition-case err
        (make-directory install-directory t)
      (error
       (error "Target cache dir is not executable or writable: cannot create %s: %s"
              (dtach-bootstrap--install-directory-target-name directory)
              (error-message-string err))))
    (unless (file-directory-p install-directory)
      (error "Target cache dir is not executable or writable: not a directory: %s"
             (dtach-bootstrap--install-directory-target-name directory)))
    (unless (file-writable-p install-directory)
      (error "Target cache dir is not executable or writable: not writable: %s"
             (dtach-bootstrap--install-directory-target-name directory)))
    (unless (file-executable-p install-directory)
      (error "Target cache dir is not executable or writable: not executable: %s"
             (dtach-bootstrap--install-directory-target-name directory)))
    install-directory))

(defun dtach-bootstrap--chmod-target (directory target-local-file)
  "Run chmod +x for TARGET-LOCAL-FILE on DIRECTORY's target."
  (pcase-let ((`(,status . ,output)
               (dtach-bootstrap--call-target directory "chmod" "+x" target-local-file)))
    (unless (equal status 0)
      (error "Remote chmod failed: chmod +x %s exited with %S: %s"
             target-local-file status output))))

(defun dtach-bootstrap-install (&optional directory)
  "Build with Nix, install dtach on DIRECTORY's target, and return target path."
  (interactive)
  (let* ((directory (dtach-bootstrap--directory directory))
         (_probe (dtach-bootstrap--ensure-supported-target directory))
         (source (dtach-bootstrap--nix-built-binary))
         (_install-directory (dtach-bootstrap--ensure-target-cache-directory directory))
         (destination (dtach-bootstrap--installed-file-name directory))
         (target-name (dtach-bootstrap--installed-target-name directory)))
    (condition-case err
        (copy-file source destination t)
      (error
       (error "TRAMP copy failed: %s -> %s: %s"
              source target-name (error-message-string err))))
    (dtach-bootstrap--chmod-target directory target-name)
    (dtach-bootstrap--maybe-smoke-test directory target-name)
    (when (called-interactively-p 'interactive)
      (message "%s" target-name))
    target-name))

(defun dtach-bootstrap--strategy-functions ()
  "Return the install strategy dispatch table."
  `((system . ,#'dtach-bootstrap--system-dtach)
    (cached . ,#'dtach-bootstrap--cached-dtach)
    (nix . ,#'dtach-bootstrap-install)))

(defun dtach-bootstrap--effective-strategies ()
  "Return the effective strategy order."
  (let ((strategies (copy-sequence dtach-bootstrap-install-strategies)))
    (if dtach-bootstrap-prefer-system-dtach
        strategies
      (append (remove 'system strategies)
              (when (memq 'system strategies) '(system))))))

(defun dtach-bootstrap--run-strategy (strategy directory)
  "Run STRATEGY for DIRECTORY and return executable path or nil."
  (let ((fn (alist-get strategy (dtach-bootstrap--strategy-functions))))
    (unless fn
      (error "Unknown dtach-bootstrap strategy: %S" strategy))
    (funcall fn directory)))

(defun dtach-bootstrap-ensure-for-directory (directory)
  "Ensure dtach exists on DIRECTORY's target and return its target-local path."
  (let ((directory (dtach-bootstrap--directory directory)))
    (dtach-bootstrap--ensure-supported-target directory)
    (catch 'found
      (dolist (strategy (dtach-bootstrap--effective-strategies))
        (let ((path (dtach-bootstrap--run-strategy strategy directory)))
          (when path
            (throw 'found path))))
      (error "No dtach-bootstrap strategy produced a usable dtach"))))

(defun dtach-bootstrap-ensure ()
  "Ensure dtach exists on `default-directory' target and return target-local path."
  (interactive)
  (let ((path (dtach-bootstrap-ensure-for-directory default-directory)))
    (when (called-interactively-p 'interactive)
      (message "%s" path))
    path))

(defun dtach-bootstrap-executable-for-directory (directory)
  "Return a usable target-local dtach path for DIRECTORY.

This is an alias for `dtach-bootstrap-ensure-for-directory'."
  (dtach-bootstrap-ensure-for-directory directory))

(defun dtach-bootstrap-doctor (&optional directory)
  "Return diagnostic information for DIRECTORY's target."
  (interactive)
  (let* ((directory (dtach-bootstrap--directory directory))
         (probe (dtach-bootstrap--probe-target directory))
         (system-dtach (ignore-errors (dtach-bootstrap--system-dtach directory)))
         (cached-dtach (ignore-errors (dtach-bootstrap--cached-dtach directory)))
         (flake-directory (ignore-errors (dtach-bootstrap--resolve-flake-directory)))
         (nix (ignore-errors (dtach-bootstrap--nix-executable)))
         (report (list :directory directory
                       :target-system (plist-get probe :system)
                       :target-machine (plist-get probe :machine)
                       :system-dtach system-dtach
                       :cached-dtach cached-dtach
                       :install-target (dtach-bootstrap--installed-target-name directory)
                       :nix-command nix
                       :nix-flake-directory flake-directory
                       :nix-package dtach-bootstrap-nix-package)))
    (when (called-interactively-p 'interactive)
      (message "%S" report))
    report))

(defun dtach-bootstrap-detached-program ()
  "Return a dtach program path suitable for assigning to `detached-dtach-program'."
  (dtach-bootstrap-ensure))

(defun dtach-bootstrap--detached-current-program ()
  "Return the current detached dtach program, or nil."
  (when (and (boundp 'detached-dtach-program)
             (stringp (symbol-value 'detached-dtach-program))
             (not (string-empty-p (symbol-value 'detached-dtach-program))))
    (symbol-value 'detached-dtach-program)))

(defun dtach-bootstrap--detached-program-usable-p (directory program)
  "Return non-nil when PROGRAM is usable on DIRECTORY's target."
  (when program
    (condition-case nil
        (let ((executable (if (file-name-absolute-p program)
                              program
                            (pcase-let ((`(,status . ,output)
                                         (dtach-bootstrap--call-target
                                          directory "sh" "-lc"
                                          (format "command -v %s 2>/dev/null"
                                                  (shell-quote-argument
                                                   program)))))
                              (when (and (equal status 0)
                                         (string-prefix-p "/" output))
                                output)))))
          (when executable
            (dtach-bootstrap--maybe-smoke-test directory executable)
            program))
      (error nil))))

(defun dtach-bootstrap--detached-bootstrap-program (directory current-program)
  "Maybe bootstrap dtach for DIRECTORY when CURRENT-PROGRAM is unavailable."
  (pcase dtach-bootstrap-detached-missing-action
    ('bootstrap
     (dtach-bootstrap-ensure-for-directory directory))
    ('prompt
     (if (y-or-n-p
          (format "Detached dtach program %S is not usable on %s; bootstrap dtach there? "
                  (or current-program "dtach")
                  directory))
         (dtach-bootstrap-ensure-for-directory directory)
       (user-error "Detached dtach program is not usable and bootstrap was declined")))
    ('error
     (user-error "Detached dtach program %S is not usable on %s"
                 (or current-program "dtach")
                 directory))
    (_
     (error "Unknown `dtach-bootstrap-detached-missing-action': %S"
            dtach-bootstrap-detached-missing-action))))

(defun dtach-bootstrap--detached-program-for-directory (directory)
  "Return a detached dtach program for DIRECTORY, prompting if missing."
  (let ((current-program (dtach-bootstrap--detached-current-program)))
    (or (dtach-bootstrap--detached-program-usable-p directory current-program)
        (dtach-bootstrap--cached-dtach directory)
        (dtach-bootstrap--detached-bootstrap-program directory current-program))))

(defun dtach-bootstrap--detached-session-directory-for-directory (directory)
  "Return detached session directory suitable for DIRECTORY."
  (if (dtach-bootstrap--remote-prefix directory)
      dtach-bootstrap-detached-session-directory
    (when (boundp 'detached-session-directory)
      (symbol-value 'detached-session-directory))))

(defun dtach-bootstrap--detached-directory-from-session (session)
  "Return the target directory for detached SESSION."
  (cond
   ((and session (fboundp 'detached-session-working-directory))
    (detached-session-working-directory session))
   (t
    default-directory)))

(defun dtach-bootstrap-setup-detached (&optional directory)
  "Set `detached-dtach-program' for DIRECTORY's target.

When called interactively, DIRECTORY defaults to `default-directory'.  This is
a one-time assignment.  For automatic per-target setup before each detached
session, enable `dtach-bootstrap-detached-mode'."
  (interactive)
  (unless (boundp 'detached-dtach-program)
    (error "detached-dtach-program is not bound; load detached.el first"))
  (setq detached-dtach-program
        (dtach-bootstrap-ensure-for-directory
         (dtach-bootstrap--directory directory)))
  detached-dtach-program)

(defun dtach-bootstrap--detached-connection-local-variables (&optional program)
  "Return detached.el connection-local variables.

PROGRAM is a target-local dtach program selected for the current target."
  (append
   `((detached-session-directory . ,dtach-bootstrap-detached-session-directory))
   (when program
     `((detached-dtach-program . ,program)))))

(defun dtach-bootstrap-setup-detached-connection-local (&optional program)
  "Install connection-local detached.el defaults for TRAMP sessions.

This configures `detached-session-directory' for the criteria in
`dtach-bootstrap-detached-tramp-criteria'.  When PROGRAM is non-nil, it also
sets `detached-dtach-program' for detached's connection-local command
generation."
  (interactive)
  (connection-local-set-profile-variables
   dtach-bootstrap-detached-connection-profile
   (dtach-bootstrap--detached-connection-local-variables program))
  (dolist (criteria dtach-bootstrap-detached-tramp-criteria)
    (connection-local-set-profiles
     criteria
     dtach-bootstrap-detached-connection-profile)))

(defun dtach-bootstrap--around-detached-start-session (orig-fun &rest args)
  "Ensure detached has a usable dtach before calling ORIG-FUN with ARGS."
  (let* ((session (car args))
         (directory (dtach-bootstrap--directory
                     (dtach-bootstrap--detached-directory-from-session session)))
         (detached-dtach-program
          (dtach-bootstrap--detached-program-for-directory directory)))
    (dtach-bootstrap-setup-detached-connection-local detached-dtach-program)
    (apply orig-fun args)))

(defun dtach-bootstrap--around-detached-create-session (orig-fun &rest args)
  "Bind detached remote defaults before ORIG-FUN creates a session."
  (dtach-bootstrap-setup-detached-connection-local)
  (apply orig-fun args))

(defun dtach-bootstrap--around-detached-valid-dtach-executable-p (orig-fun session)
  "Validate dtach for SESSION using dtach-bootstrap before ORIG-FUN.

Detached's own validator uses `executable-find', which does not reliably
validate target-local absolute paths for TRAMP sessions.  dtach-bootstrap has
already smoke-tested the selected program for the target."
  (if (dtach-bootstrap--remote-prefix
       (dtach-bootstrap--detached-directory-from-session session))
      (progn
        (dtach-bootstrap--detached-program-for-directory
         (dtach-bootstrap--detached-directory-from-session session))
        t)
    (funcall orig-fun session)))

(defun dtach-bootstrap--around-detached-watch-session-directory (orig-fun session-directory)
  "Call ORIG-FUN for SESSION-DIRECTORY, ignoring unsupported remote watches."
  (condition-case err
      (funcall orig-fun session-directory)
    (file-notify-error
     (unless (file-remote-p session-directory)
       (signal (car err) (cdr err))))))

(defun dtach-bootstrap--enable-detached-advice ()
  "Enable dtach-bootstrap advice for detached.el."
  (dtach-bootstrap-setup-detached-connection-local)
  (if (fboundp 'detached-start-session)
      (progn
        (unless (advice-member-p #'dtach-bootstrap--around-detached-create-session
                                 'detached-create-session)
          (advice-add 'detached-create-session
                      :around #'dtach-bootstrap--around-detached-create-session))
        (unless (advice-member-p #'dtach-bootstrap--around-detached-start-session
                                 'detached-start-session)
          (advice-add 'detached-start-session
                      :around #'dtach-bootstrap--around-detached-start-session))
        (when (fboundp 'detached--valid-dtach-executable-p)
          (unless (advice-member-p #'dtach-bootstrap--around-detached-valid-dtach-executable-p
                                   'detached--valid-dtach-executable-p)
            (advice-add 'detached--valid-dtach-executable-p
                        :around #'dtach-bootstrap--around-detached-valid-dtach-executable-p)))
        (when (fboundp 'detached--watch-session-directory)
          (unless (advice-member-p #'dtach-bootstrap--around-detached-watch-session-directory
                                   'detached--watch-session-directory)
            (advice-add 'detached--watch-session-directory
                        :around #'dtach-bootstrap--around-detached-watch-session-directory))))
    (with-eval-after-load 'detached
      (when dtach-bootstrap-detached-mode
        (dtach-bootstrap--enable-detached-advice)))))

(defun dtach-bootstrap--disable-detached-advice ()
  "Disable dtach-bootstrap advice for detached.el."
  (when (fboundp 'detached-create-session)
    (advice-remove 'detached-create-session
                   #'dtach-bootstrap--around-detached-create-session))
  (when (fboundp 'detached-start-session)
    (advice-remove 'detached-start-session
                   #'dtach-bootstrap--around-detached-start-session))
  (when (fboundp 'detached--valid-dtach-executable-p)
    (advice-remove 'detached--valid-dtach-executable-p
                   #'dtach-bootstrap--around-detached-valid-dtach-executable-p))
  (when (fboundp 'detached--watch-session-directory)
    (advice-remove 'detached--watch-session-directory
                   #'dtach-bootstrap--around-detached-watch-session-directory)))

;;;###autoload
(define-minor-mode dtach-bootstrap-detached-mode
  "Prompt to bootstrap dtach when detached.el cannot find it.

This mode advises `detached-start-session'.  The advice dynamically binds
`detached-dtach-program' for the current `default-directory'.  If the current
detached program is usable on the target, it is left alone.  If it is missing,
the behavior is controlled by `dtach-bootstrap-detached-missing-action'."
  :global t
  :group 'dtach-bootstrap
  (if dtach-bootstrap-detached-mode
      (dtach-bootstrap--enable-detached-advice)
    (dtach-bootstrap--disable-detached-advice)))

(provide 'dtach-bootstrap)

;;; dtach-bootstrap.el ends here
