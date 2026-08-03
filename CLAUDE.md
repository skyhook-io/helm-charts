# Repository agent instructions

`AGENTS.md` is a symlink to this file so every supported agent reads the same
policy. Edit `CLAUDE.md`; do not replace the symlink with a separate copy.

## Release authorization boundary

Every push to `main` runs `.github/workflows/release.yml`, whose chart-releaser
job can publish new chart archives, Git tags, GitHub Releases, and Helm index
entries. It compares the pushed tree with the latest reachable Git tag and
packages every changed chart directory. An unrelated commit can therefore
publish a chart change left behind by any earlier, unsuccessful release.

Before landing anything on `main`, fetch current `origin/main` and remote tags.
Use the exact tree that would land, updated onto that `origin/main`; a stale
topic branch is not a valid preflight target. Diff it against
`git describe --tags --abbrev=0 origin/main`, limited to `charts/`, and verify
that baseline tag exists in `git ls-remote --tags origin`. If the baseline is
not remote or any chart directory appears in the diff, assume the push will run
packaging, release, and index steps. This is a release action even when the
chart version appears to be published already: the workflow can attempt to
publish it again or fail partway through.

For release-state review, consider an affected chart's current
`<name>-<version>` fully published only when a matching remote Git tag, GitHub
Release, and published Helm index entry all exist.

Do not perform any of the following without explicit user approval that names
the exact artifact, exact version, and publication action:

- land a commit on `main` by merge, squash, rebase, merge queue, auto-merge, or
  direct push when that preflight finds an affected chart directory;
- push to `gh-pages` or otherwise edit the published Helm index;
- create, move, or delete a remote Git tag or GitHub Release;
- run or dispatch a release/publish workflow;
- publish, replace, delist, or delete a chart archive or Helm index entry.

Editing chart sources, chart `version` or `appVersion`, or image references;
committing; pushing a topic branch; opening or updating a pull request; and
running non-publishing validation are ordinary preparation. They do not
authorize publication. A generic instruction to merge is also insufficient
when landing would publish.

If publication is the requested next step, state the exact artifact, version,
and action and ask for confirmation. The user's affirmative reply to that
specific proposal is sufficient; do not ask them to repeat the names again. A
user-initiated instruction that already names the artifact, version, and action
is also sufficient.
