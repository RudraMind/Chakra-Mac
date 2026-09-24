# How to check this really came from us

You downloaded a Mac app from the internet. That is a reasonable thing to be careful about.
This page tells you exactly what you can and cannot prove, in plain terms, with no marketing.

**The short version:** macOS will warn you that it cannot check this app, and that warning is
accurate. But you can verify the download yourself in one command, and — unusually — you can
read the source and build it yourself. A clean build took **16 seconds** on an M-series Mac,
measured, with nothing to install beyond Apple's command line tools.

---

## Start here: what the scary dialog means

On first launch macOS will refuse to open it with a dialog titled **"Chakra" Not Opened**,
saying *"Apple could not verify "Chakra" is free of malware that may harm your Mac or
compromise your privacy."* The dialog offers only **Done** and **Move to Trash** — there is
no Open button.

That is true. Apple has not inspected Chakra. Getting Apple to inspect an app (*notarization*)
requires a paid Apple Developer account at $99/year, which this project does not have.

So the dialog is not a bug and not a false alarm. It is macOS correctly telling you that the
usual chain of trust is absent. What follows is what you can check instead.

---

## Level 1 — the checksum. Proves the file is intact.

Every release publishes a SHA-256 for `Chakra.dmg`. Compare it:

```bash
shasum -a 256 ~/Downloads/Chakra.dmg
```

**Proves:** the file you have is byte-for-byte the file on the release page. Catches a
corrupted or truncated download.

**Does not prove:** that the release page is trustworthy. If someone could replace the file,
they could replace the number beside it. On its own, this is weak.

---

## Level 2 — build provenance. Proves it came from this source code.

This one is genuinely strong, and it is the answer to "how do I know you built it".

You need the [GitHub CLI](https://cli.github.com) (`brew install gh`), **and you must be
logged in** — `gh attestation verify` requires a token even for a public repository:

```bash
gh auth login          # once, if you have never used gh before
gh attestation verify ~/Downloads/Chakra.dmg --repo RudraMind/Chakra-Mac
```

Without the login step you get an authentication error rather than a verification result.

A good result looks roughly like this. Yours will list your own digest and may show more
lines — the shape is what matters, and the decisive parts are the exit status and the
`✓ Verification succeeded!` line:

```
Loaded digest sha256:… for file:///Users/you/Downloads/Chakra.dmg
Loaded 1 attestation from GitHub API

The following policy criteria will be enforced:
- Predicate type must match ................ https://slsa.dev/provenance/v1
- Source Repository Owner URI must match ... https://github.com/RudraMind
- Source Repository URI must match ......... https://github.com/RudraMind/Chakra-Mac
- OIDC Issuer must match ................... https://token.actions.githubusercontent.com

✓ Verification succeeded!

The following attestation matched the policy criteria

- Attestation #1
  - Build repo: RudraMind/Chakra-Mac
  - Build workflow: .github/workflows/release.yml@refs/tags/v1.0
  - Signer repo: RudraMind/Chakra-Mac
  - Signer workflow: .github/workflows/release.yml@refs/tags/v1.0
```

A failure prints one of `✗ No attestations found for subject <digest>`,
`✗ Sigstore verification failed`, or `✗ Policy verification failed`, and exits non-zero.

**Proves:** this exact disk image was built by this repository's own CI, from a specific
commit, by the workflow you can read at
[`.github/workflows/release.yml`](.github/workflows/release.yml). It is a
[Sigstore](https://www.sigstore.dev/) signature, and a copy is written to a public,
append-only transparency log. **Nobody can forge this without control of this GitHub
repository.**

**Does not prove:** the legal identity of a human being. What it proves is arguably more
useful for open source — that the binary you are about to run corresponds to source code you
can read.

**Important:** macOS does not check this. Verifying here does **not** make the first-launch
dialog go away.

---

## Level 3 — signed commits. Proves who wrote the code, when present.

**Check rather than assume.** Commit signing is recommended in this project's ship runbook but
is not enforced by CI, so look for the evidence instead of taking this page's word for it:

- Open any commit on GitHub. A green **Verified** badge means it carries a signature from a
  key registered on the maintainer's account. **No badge means no signature** — GitHub does
  not label unsigned commits.
- For a release tag:

  ```bash
  git clone https://github.com/RudraMind/Chakra-Mac.git
  cd Chakra
  git tag -v v1.0        # "Good ... signature" and exit 0 if signed
  ```

  Local tag verification also needs `gpg.ssh.allowedSignersFile` configured with the
  maintainer's public key; without it the command fails even for a validly signed tag. GitHub's
  badge does not have that requirement.

**Proves, where the signature exists:** the code and the release tag were signed by whoever
holds that key.

**Does not prove:** anything about the file you downloaded. That is Level 2's job.

---

## Level 4 — don't trust us at all. Build it yourself.

This is the strongest option, and Chakra is deliberately built so that it is realistic rather
than theoretical.

```bash
git clone https://github.com/RudraMind/Chakra-Mac.git
cd Chakra
./build.sh
cp -R build/Chakra.app /Applications/
```

**There is nothing to install first** except Apple's command line tools
(`xcode-select --install`). No package manager. No dependency to audit. No project file to
open. Six readable shell scripts drive the Swift compiler directly, and every line of code is
in this repository.

You can also check the two claims that matter most, in one command each:

```bash
# Does it make any network connection? (no output = no networking code exists)
grep -rniE "URLSession|NSURLConnection|http://|https://|CFSocket" Sources/ Tools/

# What system frameworks does it use?
grep -rhoE "^import [A-Za-z]+" Sources/*.swift | sort -u
```

The second should list exactly seven, all shipped with macOS: `AppKit`, `Carbon`,
`CoreGraphics`, `CoreServices`, `Foundation`, `ServiceManagement`,
`UniformTypeIdentifiers`.

An app you compiled yourself from source you read needs no trust in us at all.

---

## What we cannot offer, and why

**A signature with our name in it.** Run this on the app and you will see:

```bash
# Note the 2>&1 — codesign writes everything to stderr, so without it a pipe
# or a redirect shows nothing at all.
codesign -dvvv /Applications/Chakra.app 2>&1 | grep -E "Signature|TeamIdentifier|Authority"
```

Sixteen lines come back in full; these are the two that matter, and there is **no `Authority`
line at all**:

```
Signature=adhoc
TeamIdentifier=not set
```

*Ad-hoc* means signed by nobody. There is no `Authority=Developer ID Application: ...` line,
because there is no Developer ID. That is the honest state of things: only a paid Apple
Developer certificate puts a verified name into an app bundle, and only notarization makes
macOS stop warning about it.

We would rather tell you that plainly than imply the app is signed when it is not.

**A consequence worth knowing:** because the signature is ad-hoc, macOS treats every rebuild
as a different program. If you enable "Open at login", it will need re-approving after each
update.

---

## Summary

| What you want to know | How | Strength |
|---|---|---|
| Is the file intact? | `shasum -a 256` vs the release page | weak alone |
| Did it come from this source code? | `gh attestation verify` | **strong** |
| Who wrote the code? | Verified badge, `git tag -v` | strong for source |
| Do I have to trust anyone? | `./build.sh` — build it yourself | **strongest** |
| Has Apple checked it? | **No, and we cannot make it so.** | — |

If something here does not match what you observe, that is worth reporting — see
[`SECURITY.md`](SECURITY.md).
