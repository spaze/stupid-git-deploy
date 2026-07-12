# stupid-git-deploy

A stupidly simple bash script to deploy a site from Git(Hub): fetch, check out the
new code, run `composer install --no-dev`, purge the cache, strip dev dependencies, and
hit the site as a healthcheck.

Before deploying anything, it verifies that the code was **authorized by you**:
it will only deploy a commit that a Git tag named `deploy`, signed with *your*
SSH key, points at. See [What this protects](#what-this-protects-and-what-it-does-not)
below for exactly what that does and does not buy you.

## How it works

1. On your workstation you review what you're about to ship, then run
   `sign-deploy`. That signs a moving `deploy` tag over your current commit
   (with your SSH key, e.g. from 1Password), force-pushes it, and triggers the
   deploy over ssh.
2. On the server, `deploy <site>` fetches the tag, checks its signature against a
   local allow-list of your public key(s), and refuses to continue unless it's a
   valid, fast-forward-only move. Only then does it check out the new code. Any
   `docs/deploy/init` and `conf/deploy/init` hooks in the current checkout run
   before that verification.

The tag is *authorization* ("I, holder of the key, approve deploying this"). The
server never trusts GitHub, a password, a token, or its own push credentials for
that decision — only your off-machine signing key.

## Installation

### On the server (where the site is deployed)

Symlink the scripts and completion:

1. `~/.local/bin/deploy` (or `~/bin/deploy`) → `deploy`
2. `~/.local/bin/git_ssh_wrapper` (or `~/bin/git_ssh_wrapper`) → `git_ssh_wrapper`
3. `~/.local/share/bash-completion/completions/deploy` → `deploy_bash_completion`
   – the symlink's filename has to be `deploy`, otherwise the completion won't work

Then create the **allow-list of signing keys** — this is the one required piece
of trust configuration. It holds the *public* half of the SSH key you sign tags
with; it is what lets the server tell your tag from anybody else's:

```sh
mkdir -p ~/.config/deploy
# one line per authorized key; the first field is a label of your choice (Git ignores it)
echo 'you@example.com ssh-ed25519 AAAA...your-signing-pubkey...' > ~/.config/deploy/allowed_signers
```

Overridable via env:

- `STUPID_GIT_DEPLOY_ALLOWED_SIGNERS` (default `~/.config/deploy/allowed_signers`)
- `STUPID_GIT_DEPLOY_LOCK` (default `~/.local/state/deploy/locks/<site>.lock`)
- `STUPID_GIT_DEPLOY_LOG` (default `~/.local/state/deploy/deploy.log`)
- `STUPID_GIT_DEPLOY_ROOT` (default `/srv/www`)
- `STUPID_GIT_DEPLOY_TAG` (default `deploy`)

Requires **Git ≥ 2.34** (for SSH signature verification) and **`flock`** (from
util-linux, for the per-site lock); the script refuses to run without them.

Deploys of the same site are serialized with a lock: if one is already running,
a second run of that site exits immediately rather than racing on it. Different
sites deploy independently.

The meaningful outcomes are appended to the deploy log with the site and commit
SHAs: successful deploys (`ok`) and — importantly — the two verification
refusals, an unauthorized signature (`badsig`) and a rejected
rollback/non-fast-forward (`nonff`). It's a plain local file, so treat it as an
audit aid, not a tamper-proof record. Operational aborts (Git too old, fetch
failed, and so on) print a message and exit without a log line.

### On your workstation (where you deploy from)

1. Symlink `sign-deploy` into your `PATH`, e.g. `~/.local/bin/sign-deploy` → `sign-deploy`.
2. Make sure Git is set up to SSH-sign (once, globally):
   `git config --global gpg.format ssh` and
   `git config --global user.signingkey key::ssh-ed25519 AAAA...` (or your 1Password
   config). The *public* key must match a line in the server's `allowed_signers`.
3. Tell each repository what it deploys and where, with two `git config` values
   (once per checkout):
   ```sh
   git config --local stupid-git-deploy.site michalspacek.cz # what to deploy (the site name)
   git config --local stupid-git-deploy.host web.example.com # the server to deploy it on
   ```
   Then `sign-deploy` — with no argument — deploys that site. `<host>` is
   whatever you'd `ssh` to. Pass a site explicitly to override the config
   (`sign-deploy other.example`), or set
   `STUPID_GIT_DEPLOY_HOST=your.server.example` for a one-off host. A repository
   with neither `stupid-git-deploy.site` nor an argument (or with no
   `stupid-git-deploy.host`) prints how to set them.

   By default `sign-deploy` runs `~/.local/bin/deploy` on the server (the `~` is
   expanded there, so it works even if your home directory differs). Set
   `STUPID_GIT_DEPLOY_REMOTE` only if you installed `deploy` somewhere else.

   `sign-deploy` connects with `ssh` by default; set `STUPID_GIT_DEPLOY_SSH` to
   use a different client — e.g. `ssh.exe` on WSL, so authentication uses the
   Windows-side agent (such as 1Password) instead of WSL's own ssh.

## Deploying

```sh
git pull # get the merged code
git log --oneline <last>.. # REVIEW what you're about to ship (see below)
sign-deploy # sign, push the tag, trigger the server (site from git config)
```

Because your signature *is* the authorization, the review step is not optional —
see below.

## What this protects, and what it does not

Plain English, so there are no surprises.

### What it protects against

- **Deploying anything you didn't sign off on.** Nothing reaches the site unless
  it carries a `deploy` tag signed by your SSH key. Someone with a stolen GitHub
  password, a stolen API token, push access to the repo, or even control of
  GitHub itself **cannot** forge that signature — your signing key never leaves
  your machine / 1Password.
- **Tampering with the exact code deployed.** The signature is bound to the exact
  commit, which is bound to every file in it. Change one byte and the signature no
  longer matches, so the server refuses it.
- **Rollback / replay attacks.** You can't be tricked into re-deploying an older
  (perhaps vulnerable) version by replaying an old signed tag — the server only
  moves *forward* (fast-forward-only) and refuses to go back.
- **A compromised GitHub.** The server doesn't trust GitHub's own commit
  signatures at all, so a compromise on GitHub's side still can't get code onto
  your server without your signature.

### What it does NOT protect against

- **A malicious commit you didn't notice before signing.** The server does *not*
  check who wrote each individual commit between the last deploy and now — it
  trusts that when you signed the tag, you looked. If you sign without reviewing,
  a bad commit hidden inside a merged pull request (say, from a compromised
  contributor or dependency PR) **will be deployed**. Reviewing the changes
  before `sign-deploy` is the control that catches this; it is the price of the
  simple design. Deploying many times a day, the real risk here is rubber-stamping.
- **Theft of your signing key.** Whoever holds your SSH signing key (1Password)
  can authorize a deploy of anything. This scheme puts all trust in that one key.
- **What's inside Git submodules.** The signature pins *which* submodule commit is
  used, but the server doesn't verify the contents behind that pin — a submodule
  points at a separate repo with its own trust.
- **Someone hiding newer commits from you (a "freeze").** If the origin quietly
  withholds updates, you'll simply keep deploying your latest known-good version.
  That's safe (nothing malicious ships), just not fresh.
- **Rollbacks.** There's no rollback command — the forward-only rule is
  deliberate. To undo, make a new commit that reverts the change and deploy that.
- **The code already on the server at setup.** The forward-only rule is anchored
  on whatever commit the server currently has checked out, and that starting
  point is trusted as-is (never signature-checked). Set the server up at a
  known-good commit; the "nothing ships without your signature" guarantee applies
  to everything deployed *after* that first point.

### Rotating your key

Add the new public key as another line in the server's `allowed_signers`. Keep
the old line until every server has been deployed at least once with the new key,
then remove it.
