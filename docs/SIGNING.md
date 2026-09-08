# Release signing

LabDesk uses separate update and Windows publisher signatures. A release is not accepted merely because a build finishes.

## Signed update manifests

The updater pins the raw 32-byte Ed25519 public key from `res/release-signing-public-key`. It verifies the detached 64-byte `SHA256SUMS.sig` over the exact bytes of `SHA256SUMS`, then verifies the selected asset digest before installation. An empty or malformed key, missing signature, altered manifest, duplicate asset entry or wrong file digest fails closed. There is no unsigned fallback.

The release key is generated and used on the Windows signing machine by `scripts/release_sign.py`. Its private bytes are encrypted with CurrentUser Windows DPAPI and stored outside the checkout. The directory disables inherited permissions and grants only the current user and SYSTEM. Plaintext private bytes are never written to a file, command argument or log. The public pin is committed with the application source.

The September 8, 2026 private candidate uses this public pin:

```
lR7XJ4eIBwPVFPOI3W25mYam+K6v3oLtTcHy+PWxDpE=
```

This key is not a Cloudflare runtime/build secret or GitHub Actions secret. Cloud build access must not imply release-signing authority. The release-checksums workflow now has read-only repository permission and verifies the offline signature and complete release inventory. It has no private-key input, signing step, checksum replacement or upload permission. The obsolete unsigned-manifest publisher in the Flutter build workflow has been removed. Publish the locally verified assets, manifest and signature together after all final assets are ready. Missing signatures, modified files and extra unsigned assets fail verification.

### Initializing a new product key

This is a one-time operation, not a routine build step. The script refuses to replace an existing key directory or nonempty application pin. Do not delete the existing pin to work around that refusal. A key change requires a planned trust migration for existing installations.

```
python scripts/release_sign.py init --key-dir "$env:USERPROFILE/.labdesk/release-signing" --public-key res/release-signing-public-key
```

Python's `cryptography` package is required; the verified signing environment uses version 49.0.0. Initialization performs an actual DPAPI encrypt/decrypt round trip before saving the public pin. The ciphertext file is `release-key.dpapi`.

### Signing final artifacts

Finish any Authenticode signing first because it changes file bytes. Use a new output directory for each immutable set of assets:

```
python scripts/release_sign.py sign --key-dir "$env:USERPROFILE/.labdesk/release-signing" --public-key res/release-signing-public-key --out-dir signed-release dist/LabDesk-1.4.0-alpha.6+78-x64.msi
```

The signer checks the private key against the committed public pin, rejects ambiguous or duplicate filenames, hashes each asset, signs the manifest, and verifies its own signature. It never overwrites a previous output directory. Verify with the built application as well:

```
LabDesk.exe --verify-release-manifest signed-release/SHA256SUMS signed-release/SHA256SUMS.sig LabDesk-1.4.0-alpha.6+78-x64.msi
python scripts/test_release_sign.py
```

The native command verifies the manifest and prints the selected digest. Independently compare that digest with `Get-FileHash -Algorithm SHA256` on the exact artifact. Repeat with a deliberately modified copy of the manifest and confirm refusal. Publish only the original verified files.

### Custody, recovery and limits

DPAPI protects the key at rest from other ordinary local accounts. It does not protect it from malware running as the signing user, a compromised administrator, or compromise of the signing process. Keep the signing machine, its account and source checkout controlled. This is not a hardware-backed or offline signing device.

A copy of `release-key.dpapi` alone is not a portable recovery key. Recovery depends on the Windows user's DPAPI master keys and credentials, normally on the same machine. A tested protected backup/recovery arrangement remains a release-operations requirement; do not claim recovery is complete because ciphertext was copied. Never put plaintext private material into the repository, website, build cache or chat. Loss of the sole key requires a separately authenticated application rollout; existing clients must not silently accept a new website-provided pin.

Signatures prevent a compromised download site from inventing a new accepted artifact. They do not guarantee benign signed code, prevent denial of service or update freezing, or supply an independent clock/version-transparency service. The client rejects versions at or below its installed version, but a previously signed newer version can still be replayed until the client has installed a later one.

## Windows publisher signing

`scripts/sign-labdesk.ps1` signs an explicitly selected file using a code-signing certificate in the local Windows certificate store, then runs `signtool verify /pa`. It can sign an explicit DLL path as well as an executable or MSI; directory mode includes only EXE/MSI files. Certificate private keys do not belong in source or CI variables.

```
pwsh scripts/sign-labdesk.ps1 -Path dist/LabDesk.exe
pwsh scripts/sign-labdesk.ps1 -Path dist/LabDesk.exe -Thumbprint <verified-certificate-thumbprint>
Get-AuthenticodeSignature -LiteralPath dist/LabDesk.exe
```

A self-signed certificate can establish integrity in a deliberately managed trust environment, but is not a publicly trusted publisher identity. A valid signature does not itself guarantee that SmartScreen will allow a new application. Do not silently install trust roots or weaken signature verification to make a test pass.

On September 8, the signing machine had a private-key-bearing self-signed `CN=LabDesk, O=trapLab` certificate expiring in 2029. It was absent from both current-user and machine Root/TrustedPublisher stores. Consequently, publicly trusted Authenticode distribution is **not established**. The previously installed alpha 3 executable, core DLL and VPN executable were unsigned. Its Wintun DLL carried a valid WireGuard LLC signature. Candidate artifact verification must report the actual new files rather than extrapolating from the certificate store.

Preserve third-party signatures and license attribution. Verify the bundled driver independently. Do not re-sign driver files to impersonate their original publisher.

## Release gate

Record source revisions, compiler versions, dependency pins, every final asset hash, signature checks and the installed version/hash on both acceptance machines. The private alpha is not promoted to the stable update channel before the Labnet, application, account-revocation and separate-network acceptance gates pass. The website and console deployments must record their compatible application version and deployed Worker identity.
