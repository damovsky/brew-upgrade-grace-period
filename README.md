# brew-safe-upgrade

A supply-chain-aware Homebrew upgrader that only installs versions old enough for the community to have noticed something wrong.

## Why

Most Homebrew supply-chain attacks are discovered within days of a malicious release landing in homebrew-core. This script adds a configurable age gate: it checks when the current version string was first introduced into the formula's git history, and skips anything too recent. A legitimate 5-day-old release is almost certainly safe. A 2-hour-old release might not be.

This does **not** protect against:
- Pre-staged attacks where the malicious version waited in homebrew-core longer than your gate
- Third-party taps (these are skipped with a manual-review prompt)
- Compromised bottle CDN (mitigated by Homebrew's own checksum verification)

## Requirements

- macOS with Homebrew installed
- `curl` and `jq` (both ship with or are trivially installed via Homebrew)
- A GitHub personal access token is **strongly recommended** (see rate limits below)

## Usage

```bash
./brew-safe-upgrade.sh              # default: 5-day gate, formulae only
./brew-safe-upgrade.sh --days 7     # stricter: 7-day gate
./brew-safe-upgrade.sh --dry-run    # preview what would be upgraded
./brew-safe-upgrade.sh --casks      # also include casks
./brew-safe-upgrade.sh --log        # append clean (no ANSI) log to ~/brew-safe-upgrade.log
```

## How the age check works

For each outdated formula, the script:

1. Fetches the formula's JSON from `formulae.brew.sh` to get the current version string and the path of the Ruby formula file in homebrew-core
2. Fetches the last 10 commits touching that file from the GitHub API
3. Walks those commits from newest to oldest, checking each diff — finds the **oldest** commit whose diff contains the version string
4. That commit's date is the version publication date

This correctly handles bottle rebuilds, dependency additions, and formatting commits — those touch the formula file but don't change the version, so they don't reset the clock.

## GitHub API rate limits

Each formula requires up to 11 API calls (1 commit list + up to 10 per-commit diffs). Unauthenticated GitHub API requests are capped at **60/hour**. Without a token, you can safely process about 5 formulae per run before hitting the limit.

When the limit is near exhaustion, the script warns you upfront with the remaining count and time until reset. Packages that cannot be checked are **skipped conservatively** — they are never silently upgraded.

**Set a token to remove the limit:**

```bash
export GITHUB_TOKEN=ghp_your_token_here
./brew-safe-upgrade.sh
```

A token with no scopes (read-only public data) is sufficient.

## Third-party taps

Formulae from third-party taps (e.g. `hashicorp/tap/terraform`) are not in homebrew-core and cannot be age-verified. The script skips them with a message pointing you to run `brew upgrade <pkg>` manually after reviewing the release yourself.

## Recommended setup

Run daily via cron or launchd, with a token, logging enabled:

```bash
GITHUB_TOKEN=ghp_... /path/to/brew-safe-upgrade.sh --days 5 --casks --log
```

Add to crontab (`crontab -e`):

```
0 9 * * * GITHUB_TOKEN=ghp_... /path/to/brew-safe-upgrade.sh --days 5 --casks --log
```

## Security model

The age gate is a detection-window strategy, not a cryptographic guarantee. It assumes that malicious packages introduced into homebrew-core are discovered by the community within your configured grace period. Longer gates (7–14 days) provide more confidence at the cost of running older software longer.

The script trusts:
- `formulae.brew.sh` for formula metadata (Homebrew's official API)
- `api.github.com` for commit history (GitHub's servers set commit timestamps on merge, not the contributor)

If either of these is compromised or intercepted at the network level, the age signal is unreliable.
