;;; dtach-bootstrap-test.el --- Tests for dtach-bootstrap -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'dtach-bootstrap)

(ert-deftest dtach-bootstrap-test-target-local-file-name ()
  (should (equal (dtach-bootstrap--target-local-file-name
                  "/ssh:example:/home/me/project/")
                 "/home/me/project/"))
  (should (equal (dtach-bootstrap--target-local-file-name
                  "/ssh:me@example:/home/me/.cache/dtach-bootstrap/bin/dtach")
                 "/home/me/.cache/dtach-bootstrap/bin/dtach")))

(ert-deftest dtach-bootstrap-test-tramp-file-name ()
  (should (equal (dtach-bootstrap--tramp-file-name
                  "/home/me/.cache/dtach-bootstrap/bin/dtach"
                  "/ssh:example:/home/me/project/")
                 "/ssh:example:/home/me/.cache/dtach-bootstrap/bin/dtach"))
  (should (equal (dtach-bootstrap--tramp-file-name
                  "/tmp/dtach"
                  "/tmp/project/")
                 "/tmp/dtach")))

(ert-deftest dtach-bootstrap-test-remote-install-paths ()
  (let ((dtach-bootstrap-install-directory "~/.cache/dtach-bootstrap/bin"))
    (cl-letf (((symbol-function 'dtach-bootstrap--target-home-directory)
               (lambda (_directory) "/home/me")))
      (should (equal (dtach-bootstrap--install-directory-file-name
                      "/ssh:example:~/project/")
                     "/ssh:example:/home/me/.cache/dtach-bootstrap/bin/"))
      (should (equal (dtach-bootstrap--installed-file-name
                      "/ssh:example:~/project/")
                     "/ssh:example:/home/me/.cache/dtach-bootstrap/bin/dtach"))
      (should (equal (dtach-bootstrap--installed-target-name
                      "/ssh:example:~/project/")
                     "/home/me/.cache/dtach-bootstrap/bin/dtach")))))

(ert-deftest dtach-bootstrap-test-effective-strategies-default ()
  (let ((dtach-bootstrap-install-strategies '(system cached nix))
        (dtach-bootstrap-prefer-system-dtach t))
    (should (equal (dtach-bootstrap--effective-strategies)
                   '(system cached nix)))))

(ert-deftest dtach-bootstrap-test-effective-strategies-system-last ()
  (let ((dtach-bootstrap-install-strategies '(system cached nix))
        (dtach-bootstrap-prefer-system-dtach nil))
    (should (equal (dtach-bootstrap--effective-strategies)
                   '(cached nix system)))))

(ert-deftest dtach-bootstrap-test-find-flake-directory ()
  (let* ((root (make-temp-file "dtach-bootstrap-test-" t))
         (child (expand-file-name "lisp/subdir" root)))
    (unwind-protect
        (progn
          (make-directory child t)
          (write-region "" nil (expand-file-name "flake.nix" root))
          (should (equal (dtach-bootstrap--find-flake-directory child)
                         (file-name-as-directory root))))
      (delete-directory root t))))

(ert-deftest dtach-bootstrap-test-find-flake-directory-follows-straight-symlink ()
  (let* ((root (make-temp-file "dtach-bootstrap-test-" t))
         (repo (expand-file-name "repos/dtach-bootstrap" root))
         (build (expand-file-name "build/dtach-bootstrap" root)))
    (unwind-protect
        (progn
          (make-directory repo t)
          (make-directory build t)
          (write-region "" nil (expand-file-name "flake.nix" repo))
          (make-symbolic-link (expand-file-name "flake.nix" repo)
                              (expand-file-name "flake.nix" build))
          (should (equal (dtach-bootstrap--find-flake-directory build)
                         (file-name-as-directory repo))))
      (delete-directory root t))))

(ert-deftest dtach-bootstrap-test-nix-package-reference ()
  (let ((dtach-bootstrap-nix-package ".#dtach-x86_64-linux"))
    (should (equal (dtach-bootstrap--nix-package-reference
                    "/tmp/dtach-bootstrap/")
                   "/tmp/dtach-bootstrap#dtach-x86_64-linux"))))

(ert-deftest dtach-bootstrap-test-ensure-strategy-selection ()
  (let* ((dtach-bootstrap-install-strategies '(system cached nix))
         (dtach-bootstrap-prefer-system-dtach t)
         (seen nil)
         (strategies
          (list (cons 'system
                      (lambda (_directory)
                        (push 'system seen)
                        nil))
                (cons 'cached
                      (lambda (_directory)
                        (push 'cached seen)
                        "/home/me/.cache/dtach-bootstrap/bin/dtach"))
                (cons 'nix
                      (lambda (_directory)
                        (push 'nix seen)
                        "/should/not/run")))))
    (cl-letf (((symbol-function 'dtach-bootstrap--ensure-supported-target)
               (lambda (_directory) '(:system "Linux" :machine "x86_64")))
              ((symbol-function 'dtach-bootstrap--strategy-functions)
               (lambda () strategies)))
      (should (equal (dtach-bootstrap-ensure-for-directory "/tmp/project/")
                     "/home/me/.cache/dtach-bootstrap/bin/dtach"))
      (should (equal (nreverse seen) '(system cached))))))

(ert-deftest dtach-bootstrap-test-detached-advice-keeps-usable-program ()
  (set 'detached-dtach-program "dtach")
  (cl-letf (((symbol-function 'dtach-bootstrap--detached-program-usable-p)
             (lambda (_directory program) program))
            ((symbol-function 'dtach-bootstrap--detached-bootstrap-program)
             (lambda (&rest _)
               (error "Should not bootstrap when detached program is usable"))))
    (should (equal
             (dtach-bootstrap--around-detached-start-session
              (lambda () (symbol-value 'detached-dtach-program)))
             "dtach"))
    (should (equal (symbol-value 'detached-dtach-program) "dtach"))))

(ert-deftest dtach-bootstrap-test-detached-advice-prompts-then-binds-program ()
  (set 'detached-dtach-program "dtach")
  (let ((dtach-bootstrap-detached-missing-action 'prompt))
    (cl-letf (((symbol-function 'dtach-bootstrap--detached-program-usable-p)
               (lambda (&rest _) nil))
              ((symbol-function 'dtach-bootstrap--cached-dtach)
               (lambda (&rest _) nil))
              ((symbol-function 'y-or-n-p)
               (lambda (_prompt) t))
              ((symbol-function 'dtach-bootstrap-ensure-for-directory)
               (lambda (directory)
                 (should (equal directory default-directory))
                 "/remote/cache/bin/dtach")))
      (should (equal
               (dtach-bootstrap--around-detached-start-session
                (lambda () (symbol-value 'detached-dtach-program)))
               "/remote/cache/bin/dtach"))
      (should (equal (symbol-value 'detached-dtach-program) "dtach")))))

(ert-deftest dtach-bootstrap-test-detached-advice-uses-cache-before-prompt ()
  (set 'detached-dtach-program "dtach")
  (cl-letf (((symbol-function 'dtach-bootstrap--detached-program-usable-p)
             (lambda (&rest _) nil))
            ((symbol-function 'dtach-bootstrap--cached-dtach)
             (lambda (_directory) "/remote/cache/bin/dtach"))
            ((symbol-function 'dtach-bootstrap--detached-bootstrap-program)
             (lambda (&rest _)
               (error "Should not prompt when cached dtach is usable"))))
    (should (equal
             (dtach-bootstrap--around-detached-start-session
              (lambda () (symbol-value 'detached-dtach-program)))
             "/remote/cache/bin/dtach"))))

(ert-deftest dtach-bootstrap-test-detached-create-session-binds-session-directory ()
  (let ((default-directory "/ssh:example:~/project/")
        (dtach-bootstrap-detached-session-directory "~/.cache/detached/sessions")
        (setup-called nil))
    (cl-letf (((symbol-function 'dtach-bootstrap-setup-detached-connection-local)
               (lambda (&optional program)
                 (should-not program)
                 (setq setup-called t))))
      (should (equal
               (dtach-bootstrap--around-detached-create-session
                (lambda ()
                  :created))
               :created))
      (should setup-called))))

(ert-deftest dtach-bootstrap-test-detached-connection-local-variables ()
  (let ((dtach-bootstrap-detached-session-directory "~/.cache/detached/sessions"))
    (should (equal
             (dtach-bootstrap--detached-connection-local-variables
              "/root/.cache/dtach-bootstrap/bin/dtach")
             '((detached-session-directory . "~/.cache/detached/sessions")
               (detached-dtach-program . "/root/.cache/dtach-bootstrap/bin/dtach"))))))

(ert-deftest dtach-bootstrap-test-detached-watch-ignores-remote-file-notify-error ()
  (should-not
   (dtach-bootstrap--around-detached-watch-session-directory
    (lambda (_directory)
      (signal 'file-notify-error '("No file notification program found")))
    "/ssh:example:/home/me/.cache/detached/sessions")))

(ert-deftest dtach-bootstrap-test-setup-detached-sets-program ()
  (set 'detached-dtach-program "dtach")
  (cl-letf (((symbol-function 'dtach-bootstrap-ensure-for-directory)
             (lambda (directory)
               (should (equal directory "/ssh:example:/tmp/"))
               "/remote/cache/bin/dtach")))
    (should (equal (dtach-bootstrap-setup-detached "/ssh:example:/tmp")
                   "/remote/cache/bin/dtach"))
    (should (equal (symbol-value 'detached-dtach-program)
                   "/remote/cache/bin/dtach"))))

;;; dtach-bootstrap-test.el ends here
