This repo is 100% organic AI slop. Proceed at your own risk and do not expect maintenance. 

# dtach-bootstrap

`dtach-bootstrap` is a small Emacs package that ensures `dtach` exists on the
current local or TRAMP target and returns the target-local executable path.

It is intended for workflows where Emacs may run on macOS while detached jobs
run on Linux x86_64 hosts.


## What It Does

The default strategy order is:

```elisp
(setq dtach-bootstrap-install-strategies '(system cached nix))
```

This means:

1. Use `dtach` already on the target `PATH`.
2. Use `~/.cache/dtach-bootstrap/bin/dtach` if it was already installed.
3. Build Linux x86_64 `dtach` locally with Nix and copy it to the target.

Only Linux x86_64 targets are supported in the first pass.

## Nix Build

The flake exposes:

```sh
nix build .#dtach-x86_64-linux --print-out-paths
```

The package expects the built executable at:

```text
$out/bin/dtach
```

The flake output uses the static musl `dtach` package so the single copied
binary can run on Linux x86_64 targets without a Nix store on the target.

## API

```elisp
(dtach-bootstrap-ensure)
(dtach-bootstrap-ensure-for-directory DIRECTORY)
(dtach-bootstrap-executable-for-directory DIRECTORY)
(dtach-bootstrap-install)
(dtach-bootstrap-doctor)
```

For a remote directory:

```elisp
(dtach-bootstrap-ensure-for-directory "/ssh:host:/home/me/project/")
;; => "/home/me/.cache/dtach-bootstrap/bin/dtach"
```

The returned value is target-local, not a TRAMP path, because remote shell
commands and `detached.el` need a path meaningful on the target.

## Configuration

```elisp
(setq dtach-bootstrap-install-directory "~/.cache/dtach-bootstrap/bin"
      dtach-bootstrap-install-strategies '(system cached nix)
      dtach-bootstrap-nix-command "nix"
      dtach-bootstrap-nix-extra-arguments
      '("--extra-experimental-features" "nix-command flakes")
      dtach-bootstrap-nix-package ".#dtach-x86_64-linux"
      dtach-bootstrap-verify-after-install t)
```

`dtach-bootstrap-nix-flake-directory` defaults to the directory containing
`dtach-bootstrap.el` when it can be discovered with `locate-library`.

## use-package

```elisp
(use-package dtach-bootstrap
  :vc (:url "https://github.com/YOU/dtach-bootstrap")
  :config
  (setq dtach-bootstrap-install-strategies '(system cached nix)))
```

## Doom

For local development, add this to `packages.el`:

```elisp
(package! detached)

(package! dtach-bootstrap
  :recipe (:local-repo "/home/dcol/detach-bootstrap"
           :files ("*.el" "flake.nix" "flake.lock" "README.md")))
```

Once published, use the GitHub recipe instead:

```elisp
(package! dtach-bootstrap
  :recipe (:host github
           :repo "YOU/dtach-bootstrap"
           :files ("*.el" "flake.nix" "flake.lock" "README.md")))
```

Then configure `detached.el` and enable dtach-bootstrap's detached integration
in `config.el`:

```elisp
(use-package! detached
  :init
  (detached-init)
  :bind
  (([remap async-shell-command] . detached-shell-command)
   ([remap compile] . detached-compile)
   ([remap recompile] . detached-compile-recompile))
  :config
  (setq detached-show-output-on-attach t))

(use-package! dtach-bootstrap
  :after detached
  :config
  (setq dtach-bootstrap-install-strategies '(system cached nix)
        dtach-bootstrap-detached-missing-action 'prompt)
  (dtach-bootstrap-detached-mode 1))
```

Run `doom sync` after changing `packages.el`.

## detached.el

For automatic per-target setup, enable:

```elisp
(dtach-bootstrap-detached-mode 1)
```

This advises `detached-start-session` and binds `detached-dtach-program` to the
current usable dtach path for `default-directory`.  If detached's configured
dtach program is missing on that target, dtach-bootstrap prompts before
building and installing one.

`use-package` can also install a system package:

```elisp
(use-package detached
  :ensure-system-package (dtach . dtach))
```

That is useful when package installation should be handled by the system
package manager.  It does not by itself solve detached's per-target TRAMP
problem: when a job starts, the configured dtach program must be usable on that
specific target, and detached needs a target-local path.  That is the piece
`dtach-bootstrap-detached-mode` handles.

For one-time manual setup, call this from the buffer or project where detached
will start the job:

```elisp
(dtach-bootstrap-setup-detached)
```

It sets the global `detached-dtach-program` for the current target.

Example:

```elisp
(use-package detached
  :init
  (detached-init))

(use-package dtach-bootstrap
  :after detached
  :config
  (dtach-bootstrap-detached-mode 1))
```
