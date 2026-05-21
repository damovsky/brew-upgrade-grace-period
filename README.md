# brew-safe-upgrade

A Homebrew upgrade wrapper with a configurable age gate. Skips versions younger than N days to reduce exposure to fast-moving supply-chain attacks.

---

## The problem

When a malicious version lands in homebrew-core, it needs time to propagate before anyone notices. The window between "bad version is live" and "someone catches it and it gets pulled" is typically hours to a few days for opportunistic attacks. Running `brew upgrade` the moment a package hits your machine means you are always at the front of that exposure window.

This script adds a configurable delay: it checks when the current version was first introduced into the formula's git history, and skips anything too recent. You stay current — you just stay a few days behind the bleeding edge.

---

## Install

**Via Homebrew (recommended):**

```bash
brew tap damovsky/tap
brew install brew-safe-upgrade
```

`jq` is installed automatically as a dependency.

**Manual install (Apple Silicon):**

```bash
curl -fsSL https://raw.githubusercontent.com/damovsky/brew-upgrade-grace-period/main/brew-safe-upgrade \
  -o /opt/homebrew/bin/brew-safe-upgrade && chmod +x /opt/homebrew/bin/brew-safe-upgrade
brew install jq  # required dependency
```

**Manual install (Intel Mac):**

```bash
curl -fsSL https://raw.githubusercontent.com/damovsky/brew-upgrade-grace-period/main/brew-safe-upgrade \
  -o /usr/local/bin/brew-safe-upgrade && chmod +x /usr/local/bin/brew-safe-upgrade
brew install jq  # required dependency
```

---

## Quick start

```bash
# Preview what would be upgraded (safe — default, no changes made)
brew-safe-upgrade

# Actually apply upgrades
brew-safe-upgrade --upgrade

# Stricter gate: wait 7 days instead of 5
brew-safe-upgrade --upgrade --days 7
```

Always run without `--upgrade` first to see what the script would do.

---

## Sample output

```
╔══════════════════════════════════════════════╗
║        brew-safe-upgrade                     ║
║   supply-chain-aware Homebrew upgrader       ║
╚══════════════════════════════════════════════╝

[2026-05-21 15:31:21] ℹ  Minimum version age : 5 days
[2026-05-21 15:31:21] ℹ  Preview mode — run with --upgrade to apply

── Formulae ──────────────────────────────────────
[2026-05-21 15:31:22] ℹ  Found 8 outdated formula(e)
[2026-05-21 15:31:24] ✔  [1/8] aws-vault — 10d old → eligible for upgrade
[2026-05-21 15:31:25] ⏳ [2/8] awscli — only 0d old (need 5d) → skipping
[2026-05-21 15:31:27] ✔  [3/8] gnupg — 7d old → eligible for upgrade
[2026-05-21 15:31:28] ⏳ [4/8] gpgme — only 3d old (need 5d) → skipping
[2026-05-21 15:31:30] ✔  [5/8] helm — 7d old → eligible for upgrade
[2026-05-21 15:31:31] ⏳ [6/8] pulumi — only 2d old (need 5d) → skipping
[2026-05-21 15:31:33] ⚠  [7/8] hashicorp/tap/terraform — third-party tap, not in
                           homebrew-core. Skipping. Run 'brew upgrade hashicorp/tap/terraform'
                           manually after review.
[2026-05-21 15:31:35] ⏳ [8/8] unbound — only 0d old (need 5d) → skipping

[2026-05-21 15:31:35] ℹ  Summary (formula): upgraded=0  skipped=4  age-unknown=1  failed=0
```

---

## Usage

```
brew-safe-upgrade [OPTIONS]

OPTIONS
  --upgrade     Actually upgrade eligible packages (default is preview only)
  --dry-run     Preview what would be upgraded (same as default)
  --days N      Grace period in days, N ≥ 1 (default: 5)
  --casks       Include casks in addition to formulae
  --log         Append clean log to ~/brew-safe-upgrade.log
  --version     Print version and exit
  -h, --help    Show help with examples
```

---

## GitHub API rate limits

Each formula requires up to 11 GitHub API calls (1 commit list + up to 10 per-commit diffs to find when the current version was introduced). Unauthenticated requests are capped at **60 per hour**. Without a token you can reliably process about 5 formulae per run.

When the limit is close to exhaustion the script warns you upfront:

```
⚠  GitHub API: only 4 requests remaining (need ~15). Set GITHUB_TOKEN to avoid silent skips.
⚠  Rate limit resets in: 1823s
```

Packages that cannot be checked are **always skipped conservatively** — they are never silently upgraded.

**Set a token to remove the practical limit:**

```bash
export GITHUB_TOKEN=ghp_your_token_here
brew-safe-upgrade --upgrade
```

A token with **no scopes** (public data only) is sufficient. Create one at: GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens → No repository access.

**Recommended: store in your shell profile:**

```bash
echo 'export GITHUB_TOKEN=ghp_...' >> ~/.zshrc
```

---

## Security model

### What this protects against

Opportunistic, fast-moving supply-chain attacks where a malicious version lands in homebrew-core and is caught by the community within your configured grace period. If you use a 5-day gate and a bad release is flagged and pulled within 4 days, it never reaches your machine.

### Who is actually doing the reviewing?

- Homebrew maintainers review PRs for new formulae and significant changes
- Version bumps for established formulae are often handled by the **automated autobump bot**, which merges without human review
- Detection relies on: downstream users noticing unexpected behavior, automated security scanners (OSV, SOSS), and upstream project security channels

This is a detection-window strategy, not a guarantee. The grace period gives the community time to notice — it does not verify what is inside the package.

### Why 5 days?

5 days is a pragmatic default, not a researched threshold. It balances staying reasonably current with allowing time for detection of obvious attacks. Adjust with `--days` based on your own risk tolerance:

| Gate | Trade-off |
|------|-----------|
| 1–2 days | Catches fast-moving attacks; minimal delay |
| 5 days | Default; good balance for most users |
| 7–14 days | More confidence; you run older software longer |

### How version age is measured

The script does not use the Homebrew API to determine version age — that field does not exist. Instead it:

1. Fetches the formula's `ruby_source_path` from the Homebrew JSON API
2. Fetches the last 10 commits to that file from the GitHub commits API
3. For each commit, checks the diff to find where the current version string was first introduced
4. Uses the oldest matching commit's date as the version publication date

This correctly handles bottle rebuilds, dependency additions, and formatting changes — those touch the formula file but don't change the version string, so they don't reset the clock.

### What this does NOT protect against

- A malicious version that stays undetected longer than your gate
- Sophisticated, targeted attacks designed to evade community detection
- **Third-party taps** — not in homebrew-core, always skipped with a manual-review prompt
- Versions already installed on your machine before you started using this script
- Compromised bottle binaries (mitigated by Homebrew's own checksum verification)
- Attackers who stage a malicious version and wait patiently beyond your gate

---

## Recommended setup

Daily cron at 9am with a token, logging enabled, casks included:

```bash
# Add to crontab (crontab -e):
0 9 * * * GITHUB_TOKEN=ghp_... /usr/local/bin/brew-safe-upgrade --upgrade --casks --log
```

Or via launchd on macOS — see [launchd.info](https://launchd.info) for a plist template.

---

## Third-party taps

Formulae from third-party taps (e.g. `hashicorp/tap/terraform`, `mongodb/brew/mongodb-community`) are not in homebrew-core and cannot be age-verified through this script. They are skipped with a distinct warning pointing you to run the upgrade manually:

```
⚠  hashicorp/tap/terraform — third-party tap, not in homebrew-core.
   Skipping. Run 'brew upgrade hashicorp/tap/terraform' manually after review.
```

Before upgrading a third-party formula manually, check the tap's release notes and the upstream project's changelog.

---

## Updating

**Via Homebrew:**

```bash
brew update && brew upgrade brew-safe-upgrade
```

Note: `brew-safe-upgrade` does not apply its own age gate to itself when managed via Homebrew — use `brew upgrade brew-safe-upgrade` directly and check the [releases](https://github.com/damovsky/brew-upgrade-grace-period/releases) for what changed.

**Manual install:** re-run the same install command you used originally. It overwrites the existing binary in place. Check your current version with `brew-safe-upgrade --version` before and after.

---

## Contributing

Bug reports and PRs are welcome. Before submitting:

```bash
brew install shellcheck
shellcheck brew-safe-upgrade.sh
```

To report a **security vulnerability in this script itself**, open a GitHub issue marked `[security]`.

---

## License

MIT — see [LICENSE](LICENSE).
