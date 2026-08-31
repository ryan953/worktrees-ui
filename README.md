# Worktrees

A native macOS app that lists every git worktree on your machine and answers the one
question that matters about each: **is this work anywhere but this disk?**

| | |
| --- | --- |
| ![The worktree list, grouped by repository](docs/sidebar.png) | ![A branch whose commits are only on this machine](docs/detail-local-only.png) |

## What it shows

Worktrees are easy to accumulate and easy to forget, and the cost of forgetting one is
losing work that was never pushed. So the app keeps two facts apart rather than blending
them into a single "status":

- **Unique commits** — commits on this branch that the base branch does not have
  (`origin/main..HEAD`).
- **Pushed** — whether those commits exist on the remote, read from git's own
  remote-tracking refs.

Every worktree lands in one of these:

| Status | What it means |
| --- | --- |
| **Matches base** | Nothing here the base branch does not already have. |
| **Local only** | Commits that exist on this disk and nowhere else. |
| **Unpushed** | The branch is on GitHub, but missing some of these commits. |
| **Published** | Every commit here is on GitHub. |
| **Remote deleted** | Pushed once, then deleted — what a merged pull request leaves behind. |
| **Detached** | No branch checked out, so there is nothing to push. |

"Local only" and "Unpushed" are the two that can lose work, so they sort to the top and
the sidebar keeps a running count of them.

For anything that reached GitHub you get links to the pull request, the branch, and the
comparison against the base branch — and for pushed work with no pull request yet, a
link that opens one.

![A published branch and its pull request](docs/detail-published.png)

## Where your working copy is

Every repository group names its main working copy directory, and the detail pane keeps
it at the top with buttons to copy it, reveal it in Finder, or open a terminal there. It
is never more than a glance away, whichever worktree is selected.

### Pulling a branch into the working copy

Git will not check out a branch that is already checked out in a worktree, so the
**Pull into working copy** button offers the two honest ways around that, and shows the
exact commands before running anything:

- **Move the branch here** — detaches the worktree so the branch is free, then checks it
  out in the working copy. Commits you make afterwards land on the branch. The worktree
  keeps its files.
- **Check out the commit here** — checks out the same commit with a detached HEAD and
  leaves the worktree completely alone. Good for reading and running the code.

Both refuse to run over uncommitted changes, and the move puts the worktree back on its
branch if the checkout fails.

## Freshness

Whether a branch is "published" is read from your remote-tracking refs, so it is only as
current as your last fetch. The detail pane says when that was, and there is a **Fetch**
button per repository plus **Fetch All** in the toolbar. Fetching on every refresh is a
setting, off by default, because it is the only part that touches the network.

## Install

```sh
export HOMEBREW_GITHUB_API_TOKEN=<a token that can read this repo>
brew install --cask --no-quarantine ryan953/tap/worktrees-ui
```

The token is needed because this repository is private, and `--no-quarantine` because
the app is ad-hoc signed but not notarized. Or download the zip from
[Releases](https://github.com/ryan953/worktrees-ui/releases), unzip it into
`/Applications`, and use right-click → Open on the first launch.

### Requirements

- macOS 14 or later. The release build is universal.
- `git` on your `PATH`.
- `gh`, logged in, is optional — without it everything works except pull request links.

The app only ever reads, except for the pull button, which you confirm each time.

## Settings

- **Where to look** — the directories scanned for repositories, and how deep. Defaults
  to `~/code`, two levels down. Worktrees nested inside a repository are found by asking
  git, so they are picked up wherever they live.
- **What to read** — whether to look up pull requests, and whether to fetch on refresh.
- **Tools** — explicit paths to `git` and `gh`, and which terminal to open.

## Development

```sh
swift build
swift test
Scripts/bundle.sh --version 0.1.0   # writes dist/Worktrees.app
```

The scanner tests build real repositories in a temporary directory, push between them
and delete branches, because the classification they check is exactly the part that must
not be mocked. `Tests/WorktreesUITests/SnapshotTests.swift` renders the real views
offscreen to `.build/snapshots`.

To see what the app would report for your own machine without launching it:

```sh
WORKTREES_UI_LIVE_SCAN=1 swift test --filter LiveScanTests
```

## Releasing

Push a tag and the workflow builds a universal `Worktrees.app`, attaches the zip to a
GitHub release, and bumps the cask in
[ryan953/homebrew-tap](https://github.com/ryan953/homebrew-tap):

```sh
git tag v0.2.0 && git push origin v0.2.0
```

The tap bump needs a `TAP_TOKEN` secret with `Contents: Read+Write` on the tap and
`Contents: Read` here. Without it the release still publishes and the job summary says
how to bump the cask by hand.
