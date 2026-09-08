# Contributing to LabDesk

LabDesk welcomes contributions. The binding branch and release workflow is
[docs/WORKFLOW.md](WORKFLOW.md); read it before opening a pull request.

## Contributions

Contributions are made as GitHub pull requests against `labdesk-next`. Each pull
request is reviewed by a maintainer and either merged or given feedback on the
changes that would be required. `master` is release-only.

Should you wish to work on an issue, please claim it first by commenting on the
GitHub issue that you want to work on it, so two people do not do the same work.

## Pull Request Checklist

- Branch from `labdesk-next` and, if needed, rebase to the current `labdesk-next`
  before submitting your pull request.

- Commits should be as small as possible, while ensuring that each commit is
  correct independently (each commit should compile and pass tests).

- Commits should be accompanied by a Developer Certificate of Origin
  (http://developercertificate.org) sign-off, which indicates that you (and
  your employer if applicable) agree to be bound by the terms of the
  [project license](../LICENCE). In git, this is the `-s` option to `git commit`.

- Run the gate suite named in `docs/WORKFLOW.md` before asking for review.

- Add tests relevant to the fixed bug or new feature.

## Conduct

[docs/CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)

## Communication

Issues and pull requests on https://github.com/tfdan-cts/LabDesk are the
project's channels.