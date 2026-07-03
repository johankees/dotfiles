# Global agent instructions

Cross-repo rules. Project `CLAUDE.md`/`AGENTS.md` layer on top.

- Correct > pleasing. Reject unsafe. Offer safe alt.
- Be concise. Ask only if needed.
- No shortcuts. No workarounds. Fix root cause.
- Code style: concise > verbose.

## Temporary files

Use `$TMPDIR`: `mktemp -d "$TMPDIR/foo.XXXXXX"`. Bare `/tmp` and bare `mktemp` fail in sandbox.

## Development process

- **Research**: Read issue/PR/docs first. If sandbox blocks, write fetch script in `$TMPDIR`; user runs it.
- **Large updates**: Write short plan to `.cache/agent/plans/<ticket-or-topic-slug>.md`. Then start new agent.
- **Small commits**: One concern. Clear message.
- **Tests**: New feature: add tests if lang supports tests. Python: must. Bash: may skip. Never change existing tests
  without user consent.
- **Review**: If repo has `make pr`, run it, make it pass, fix all findings. Work not done until green. If not runnable
  in-session, `commit.sh` runs it before any commit/PR step. If no `make pr`, warn and run best available checks, e.g.
  `make lint` + `make test`.
- **Branch/PR flow**: Use `git town hack` to start work and `git town propose` to open/update PRs.
- Loop until done. Create `commit.sh` for user to sign and push.

## Commit messages

Conventional Commits: `type(scope): summary`. Types: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `ci`. Breaking:
`feat!` or `BREAKING CHANGE:`.

## Creating commits

Sandbox blocks `ssh-agent` signing. Use `commit.sh`.

For Git Town on GitHub forks:

- Set `gh` default repo to `upstream`: `gh repo set-default <upstream-owner/repo>`.
- Keep `git-town.forge-type=github` and `git-town.github-connector=gh`.
- `origin` remains the fork push remote; `git town propose` must target `upstream`.

- **Outside worktree**: Do not run `git commit`. Write repo-root `commit.sh` with exact `git add` and `git commit`.
  Include `Closes: #<number>`. User runs it.
- **Inside worktree**: Commit unsigned. Write `commit.sh` with `git resign <base>`. Base = parent of first commit, or
  `$(git merge-base HEAD <parent-branch>)`. Include issue trailer if missing.

Both variants:

- Start: `#!/usr/bin/env sh` + `set -eu`
- Overwrite old `commit.sh`
- `chmod +x`
- `commit.sh` must create the tracking issue on `upstream`, not on `origin`. Derive the upstream repo from `git remote
  get-url upstream` and pass it to `gh issue create --repo <upstream-owner/repo>`.
- If repo has `make pr` and it did not already pass in-session, `commit.sh` runs it before any `git add`, `git commit`,
  `git resign`, `git push`, or PR step. Stop on fail.
- If repo has no `make pr`, `commit.sh` prints warning.
- `commit.sh` must push the branch. Open or update the PR with `git town propose`.
- End: `rm -- "$0"`
- Do not modify repo `.gitignore`

### commit.sh skeleton

```sh
#!/usr/bin/env sh
set -eu

if make -n pr >/dev/null 2>&1; then
  make pr
else
  echo "warning: no 'make pr' target; skipped" >&2
fi

upstream_url="$(git remote get-url upstream)"
upstream_repo="${upstream_url#https://github.com/}"
upstream_repo="${upstream_repo#git@github.com:}"
upstream_repo="${upstream_repo%.git}"

issue_url="$(gh issue create --repo "$upstream_repo" --title "<issue title>" --body "<issue body>")"
issue_number="${issue_url##*/}"

git add <files>
git commit -m "<type(scope): summary>

<optional body>

Closes: #<issue>"

git push origin <branch>

git town propose

rm -- "$0"
```

## Third-party tools and dependencies

- **Stdlib**: Prefer unless third-party is justified and maintained.
- **Private registry**: Use <https://repo.ihsmarkit.com>, not public sources.
- **Local tools**: Install in `.bin`, never global.

## Validation

- **make**: Use `make help` to find checks. Fix failures. Do not weaken Makefile to pass.

## Worktrees

- **Per update**: One fresh worktree per PR-sized change. Never reuse.
- **Fresh start**: New worktree + new branch each update.
- **Location**: `~/.cache/agents/worktrees`
- **Naming**: `<repo>-<ticket-or-topic-slug>` worktree, `agent/<ticket-or-topic-slug>` branch.
- **Base**: Fetch `upstream`. Branch from current `upstream/main`.
