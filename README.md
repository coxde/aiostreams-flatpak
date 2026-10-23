# AIOStreams Desktop Flatpak remote

An unofficial, self-hosted [Flatpak](https://flatpak.org) remote for the
[AIOStreams desktop app](https://github.com/Viren070/AIOStreams/tree/main/packages/desktop).
It turns the `.flatpak` bundles that the project already publishes on GitHub
Releases into a signed OSTree repository served by GitHub Pages, so Linux users
get normal updates through `flatpak update` or their software centre.

> [!NOTE]
> This repository is a template for a **third-party** remote. It does not build
> AIOStreams from source and it is not affiliated with the upstream project. The
> best long-term option is still for upstream to publish on Flathub; see
> [Viren070/AIOStreams#1380](https://github.com/Viren070/AIOStreams/issues/1380).

## What it does

- Downloads the current Linux bundles from the upstream stable `desktop`
  release. Nightly builds are intentionally not mirrored.
- Imports every architecture (`x86_64` and `aarch64`) into an OSTree repository.
- Signs the commits and repository summary with a GPG key you control.
- Publishes the repository at `https://<owner>.github.io/<repo>/repo/`.
- Writes an `aiostreams.flatpakrepo` file that users can add in one command.

Users then get:

```sh
flatpak remote-add --if-not-exists --user aiostreams \
  https://OWNER.github.io/REPO/aiostreams.flatpakrepo
flatpak install --user aiostreams io.github.viren070.aiostreams
```

and updates with:

```sh
flatpak update --user
```

The repository is refreshed every six hours by GitHub Actions, and can also be
run manually.

## Why not point Flatpak at the release asset?

A `.flatpak` file is a single-file bundle, not a remote. Flatpak remotes need an
OSTree repository with `summary`, `objects/`, `refs/` and signed metadata.
`flatpak install --from` works on a bundle, but it cannot act as a remote and
therefore cannot be updated with `flatpak update`. This project imports those
bundles into exactly that repository layout.

## Setup

### 1. Create the repository

Push this directory to a new GitHub repository. Public repositories can use
GitHub Pages for free.

### 2. Create a signing key

On your own machine:

```sh
export GNUPGHOME="$(mktemp -d)"
gpg --batch --pinentry-mode loopback --passphrase '' --quick-generate-key \
  "AIOStreams Flatpak <you@example.com>" rsa3072 sign 5y
gpg --batch --armor --export-secret-keys > aiostreams-private.asc
gpg --batch --armor --export > aiostreams-public.asc
gpg --with-colons --list-secret-keys |
  awk -F: '/^sec:/ {print $5; exit}'
```

Keep `aiostreams-private.asc` safe and delete it from disk once it is in GitHub.
Add these repository secrets under **Settings → Secrets and variables → Actions**:

| Secret | Value |
| --- | --- |
| `FLATPAK_GPG_PRIVATE_KEY` | Contents of `aiostreams-private.asc` |
| `FLATPAK_GPG_KEY_ID` | The key ID printed above (optional; derived if omitted) |

> The key must have no passphrase: the workflow signs unattended. That also
> means the GitHub secret is as sensitive as the key itself. The public key is
> exported by the workflow and embedded in the generated
> `aiostreams.flatpakrepo`; you do not need to add it as a secret.

### 3. Run the sync

Open **Actions → Sync Flatpak remote → Run workflow**. The first run downloads
the current stable bundles, creates the repository, and pushes it to a new
`gh-pages` branch. The push that created the repository starts a run before the
signing secret exists; let it fail, then run the workflow again.

If the Pages URL is not `https://<owner>.github.io/<repo>/`, set a repository
variable `PAGES_URL` to the real base URL (ending in `/`).

### 4. Enable GitHub Pages

Now that `gh-pages` exists, go to **Settings → Pages**, set **Source** to
**Deploy from a branch**, branch `gh-pages`, folder `/ (root)`.

### 5. Install

```sh
flatpak remote-add --if-not-exists --user aiostreams \
  https://OWNER.github.io/REPO/aiostreams.flatpakrepo
flatpak install --user aiostreams io.github.viren070.aiostreams
```

Most users already have Flathub configured. If not, the app's runtime
(`org.gnome.Platform` 51) is fetched from Flathub:

```sh
flatpak remote-add --if-not-exists --user flathub \
  https://flathub.org/repo/flathub.flatpakrepo
```

### Already installed from a bundle?

A bundle install gets a private `aiostreams-origin` remote, and Flatpak will not
change that origin on a normal install or update. Add this remote and reinstall
once; the app's data in `~/.var/app/io.github.viren070.aiostreams` is kept:

```sh
flatpak install --reinstall --user aiostreams \
  io.github.viren070.aiostreams
```

After that, normal `flatpak update` updates it from this remote.

## Local use

The same script can build a repository into a local directory:

```sh
sudo apt install flatpak ostree gnupg curl      # Debian/Ubuntu
sudo dnf install flatpak ostree gnupg2 curl     # Fedora

export FLATPAK_GPG_PRIVATE_KEY="$(cat aiostreams-private.asc)"
export PAGES_URL="file:///absolute/path/to/site/"
scripts/sync-remote.sh site
```

Then add it with the generated file:

```sh
flatpak remote-add --user --if-not-exists aiostreams-local \
  "file:///absolute/path/to/site/aiostreams.flatpakrepo"
flatpak install --user aiostreams-local io.github.viren070.aiostreams
```

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `UPSTREAM_REPO` | `Viren070/AIOStreams` | GitHub repository that publishes the bundles |
| `APP_ID` | `io.github.viren070.aiostreams` | Flatpak application ID |
| `ARCHES` | `x86_64 aarch64` | Architectures to mirror |
| `STABLE_BRANCH` | `master` | Branch used for stable builds |
| `PAGES_URL` | derived from GitHub | Public base URL of the Pages site |
| `PRUNE_DEPTH` | `10` | Versions kept; older installs still update, just without a delta |
| `FLATPAK_GPG_PRIVATE_KEY` | required | Armored GPG private key |
| `FLATPAK_GPG_KEY_ID` | derived | Key ID used to sign commits and the summary |

The stable branch is deliberately `master`, because that is the branch inside
the upstream bundles. An existing bundle install is therefore the same ref, so
one `flatpak install --reinstall ...` moves it onto this remote without creating
a second copy of the app.

## Caveats

- This is a **third-party** remote. Signatures prove the repository was built by
  this workflow, not that the upstream binaries were reproducible.
- GitHub Pages is a free static host with a 1 GB published-site limit. The app's
  bundles are small and OSTree deduplicates them, but a long-lived remote should
  prune old versions or move to object storage.
- The upstream artifacts are unsigned; the workflow downloads them over HTTPS
  from a pinned repository. If you need a trust chain from source, build from
  source or wait for Flathub.
- Only the stable `desktop` release is mirrored. If the remote previously
  published nightly branches, the next sync removes them.

## License

The scripts in this repository are provided under the MIT license. AIOStreams
itself remains under its own license.
