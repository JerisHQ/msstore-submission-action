# msstore-submission-action

A GitHub Action that publishes an `.msixupload` to the Microsoft Store through
the [Microsoft Store submission API](https://learn.microsoft.com/en-us/windows/uwp/monetize/create-and-manage-submissions-using-windows-store-services),
always working on the id of the submission this run created:

```
inspect (no secrets)        publish (protected environment, after approval)
--------------------        ------------------------------------------------
package identity,           sign in -> no pending submission? -> create
version, SHA-256    ----->  -> PUT packages -> upload -> GET + field compare
                            -> commit by id -> read back by id
```

It is a composite action written in PowerShell 7 (`scripts/MsStoreRunner.psm1`),
with a Pester test suite and a fake Store API that runs on 127.0.0.1.

## Why not the Store CLI

The Microsoft Store Developer CLI (`msstore`, checked at tag v0.4.4) deletes
the app's pending submission before it creates a new one, its
`submission publish|get|delete` commands act on whatever submission is pending
at that moment rather than on a given id, and with logging on it logs the
package upload SAS URL. This action calls the REST API directly instead, and
every call after the create names this run's submission id.

## Modes

| mode | signs in | what it does |
| --- | --- | --- |
| `inspect` | no | Finds the one `.msixupload` in `package-dir`, checks the AppxManifest identity name, publisher and version, and outputs file name, version and SHA-256. Writes them to the job summary. |
| `publish` | yes | Re-checks the package (and, when given, that it is the file and SHA-256 an earlier `inspect` showed), then creates a submission, uploads, checks, commits it by id and reads it back by id. |
| `diagnose` | yes | GET calls only. Prints which fields differ between a given submission and the last published one, as field paths, never values. |
| `delete-draft` | yes | Deletes one given submission by id, only while it is the app's pending, uncommitted `PendingCommit` draft. |

### The package

The package step reads the `.msixupload` from `package-dir` once, into
memory. Its SHA-256, the read-only copy it writes to a new folder under the
runner's temp folder, and the manifest check all come from those bytes, so a
file that changes while or after it is read cannot pass the check with other
content. The publish step reads that copy twice: once to check its SHA-256
before it creates a draft, then in the upload, in one pass: each block goes
into the zip entry and into the SHA-256 together, and the zip (built in
memory, never written to disk) is sent only when that SHA-256 is the checked
one. On any other, nothing is sent.

Every read of package bytes is counted as it goes and stops one byte past
its limit, so a file that grows, or a zip entry that holds more than its
entry gives, is refused without being read further:

- The package step holds the `.msixupload` and the `.msix` unpacked from
  it in memory, the two together at most 2,000,000,000 bytes. A
  `.msixupload` whose `.msix` is about as large as itself can be at most
  about 1,000,000,000 bytes.
- It reads at most 1,048,576 bytes of `AppxManifest.xml`, and parses at
  most as many characters.
- The publish step's SHA-256 check reads at most the size the copy had when
  it was opened, itself at most 2,000,000,000 bytes, and holds one 80 KiB
  block at a time.
- The upload holds the package once, in the zip it sends: one buffer of the
  package size plus 1/1024 plus 64 KiB, set aside before the zip is built and
  sent from there with no other copy.

Before the entries of the `.msixupload`, or of the `.msix` inside it, are
listed, the package step finds that zip's central directory where .NET looks
for it (the end record, or the zip64 end record it points to) and walks it
record by record, reading 46 bytes of each. It refuses a zip with more than
65,535 entries, or with more than 16,777,216 bytes (16 MiB) of central
directory, whether its end record gives that or its records run that far.
A zip whose central directory is not found that way, or whose records are
not as many as its end record gives, is refused as a zip that cannot be
read. Listing a zip's entries keeps an object for each, with its name and
comment: measured on Linux with 65,535 entries and 16 MiB of names, .NET
kept about 67 MB (PowerShell 7.7.0, .NET 11) and 61 MB (PowerShell 7.6.10,
.NET 10) for that one zip.

These limits count package bytes only, not the memory PowerShell and .NET
use besides. Measured on Linux (PowerShell 7.6, .NET 10) with a 210 MB
`.msixupload` holding a `.msix` of about the same size, peak memory rose by
about 2.1 times the `.msixupload` in the package step and about 1.1 times in
the upload.

A file name or manifest identity field with a line break or another control
character stops the run before any output is written, and so does a file name
with workflow command text (`::` or `##[`). Package text the action prints
has workflow command syntax made inert. A package that cannot be unzipped, or
a manifest that is not XML that can be read (a DTD is refused), stops the run
with fixed text: the reader's or parser's message, which can quote the
package, is never printed. The job summary shows the file name, version and
SHA-256 as Markdown code spans whose backtick fence no backtick in the text
can close.

### The publish flow

Each step works on this run's submission id:

1. GET the app. If a submission is pending, stop: it is never deleted, changed
   or committed by this action. The stop message says whether it is an
   uncommitted draft and how to look at it (`diagnose`) or delete exactly that
   draft (`delete-draft`); a person decides.
2. POST create (`isMinimalResponse=true`); the id is taken from the answer.
3. GET the app: the pending submission must be that id.
4. GET the submission, check the price fields, then PUT it with every old
   package `PendingDelete` and the new file `PendingUpload`.
5. Upload the file to the SAS URL from the submission.
6. GET the submission again. Every field except the packages, `friendlyName`
   and the fields the service sets itself must be unchanged (field compare),
   and the draft must hold exactly the new package.
7. POST commit for that id.
8. Read that id back until it is committed with the new package version.

When a create or commit gets no answer, the action reads the app or the
submission back and reports what it shows. While the result is unconfirmed
it gives no delete or retry advice, and it never sends a change twice.

## Usage

Two jobs: `inspect` shows what will be published without any secret, and
`publish` runs in a protected environment whose required reviewers are the
human gate. `publish` stops unless the package is the one `inspect` showed.

```yaml
name: Publish to the Microsoft Store
on:
  workflow_dispatch:

permissions:
  contents: read

jobs:
  # build: a job that uploads the .msixupload as the artifact "store-package"

  inspect:
    needs: build
    runs-on: windows-latest
    outputs:
      file-name: ${{ steps.inspect.outputs.file-name }}
      sha256: ${{ steps.inspect.outputs.sha256 }}
    steps:
      - uses: actions/download-artifact@v4
        with:
          name: store-package
          path: ${{ runner.temp }}/store
      - id: inspect
        uses: JerisHQ/msstore-submission-action@<full-commit-sha>
        with:
          mode: inspect
          package-dir: ${{ runner.temp }}/store
          identity-name: Contoso.ExampleApp
          publisher: CN=00000000-0000-0000-0000-000000000000

  publish:
    needs: inspect
    runs-on: windows-latest
    environment: store          # add required reviewers to this environment
    steps:
      - uses: actions/download-artifact@v4
        with:
          name: store-package
          path: ${{ runner.temp }}/store
      - id: publish
        uses: JerisHQ/msstore-submission-action@<full-commit-sha>
        timeout-minutes: 55     # see "Timeouts"
        with:
          mode: publish
          product-id: ${{ vars.STORE_PRODUCT_ID }}
          package-dir: ${{ runner.temp }}/store
          identity-name: Contoso.ExampleApp
          publisher: CN=00000000-0000-0000-0000-000000000000
          expected-file-name: ${{ needs.inspect.outputs.file-name }}
          expected-sha256: ${{ needs.inspect.outputs.sha256 }}
          tenant-id: ${{ secrets.PARTNER_CENTER_TENANT_ID }}
          client-id: ${{ secrets.PARTNER_CENTER_CLIENT_ID }}
          client-secret: ${{ secrets.PARTNER_CENTER_CLIENT_SECRET }}
      - run: echo "committed submission ${{ steps.publish.outputs.submission-id }}"
```

Pin the action to a full commit SHA. It runs on `windows-latest` and
`ubuntu-latest` (PowerShell 7 is on both; CI tests both).

### Inputs

| input | modes | default | description |
| --- | --- | --- | --- |
| `mode` | all | (required) | `inspect`, `publish`, `diagnose` or `delete-draft` |
| `product-id` | publish, diagnose, delete-draft | | Store ID of the app (Partner Center, Product identity) |
| `package-dir` | inspect, publish | | directory with exactly one `.msixupload` |
| `identity-name` | inspect, publish | | expected AppxManifest `Identity Name` |
| `publisher` | inspect, publish | | expected AppxManifest `Identity Publisher` (`CN=...`) |
| `version` | inspect, publish | | optional expected version; it must end in `.0` either way |
| `expected-file-name` | publish | | file name an earlier `inspect` showed; the run stops on any other |
| `expected-sha256` | publish | | SHA-256 an earlier `inspect` showed; the run stops on any other |
| `submission-id` | diagnose, delete-draft | | the submission id, digits only; checked before the sign-in |
| `tenant-id` | publish, diagnose, delete-draft | | Entra tenant id (pass a secret) |
| `client-id` | publish, diagnose, delete-draft | | client id of the app registration (pass a secret) |
| `client-secret` | publish, diagnose, delete-draft | | client secret of the app registration (pass a secret) |
| `submit-minutes` | publish | `18` | deadline of the create-to-commit step (8 to 120) |
| `read-back-minutes` | publish | `30` | how long the read-back keeps trying (0 to 240) |
| `read-back-interval-seconds` | publish | `60` | seconds between read-backs (5 to 600) |
| `delete-minutes` | delete-draft | `4` | deadline of the delete-draft step (1 to 30) |

### Outputs

| output | modes | description |
| --- | --- | --- |
| `file-name` | inspect, publish | file name of the `.msixupload` |
| `version` | inspect, publish | `Identity Version` from the AppxManifest |
| `sha256` | inspect, publish | SHA-256 of the `.msixupload`, lower-case hex |
| `submission-id` | publish | id of the submission this run created and committed |

### Secrets

The action reads no secret by itself; pass these as inputs. Suggested secret
names (store them as environment secrets of the protected environment):

- `PARTNER_CENTER_TENANT_ID`
- `PARTNER_CENTER_CLIENT_ID`
- `PARTNER_CENTER_CLIENT_SECRET`

They belong to a Microsoft Entra ID application that is added to your Partner
Center account (Account settings, Users) with the Manager role (see Microsoft's
[prerequisites for the submission API](https://learn.microsoft.com/en-us/windows/uwp/monetize/create-and-manage-submissions-using-windows-store-services)).
The action signs in with client credentials and sends the secret only to
`login.microsoftonline.com` over https; API calls go only to
`manage.devcenter.microsoft.com`, the package only to `*.blob.core.windows.net`.
It never prints the secret, the access token or the SAS upload URL.

### Timeouts

A composite action cannot set a timeout on its own steps, so set
`timeout-minutes` on the step that uses it. For `publish` it must cover
`submit-minutes + read-back-minutes` plus a few minutes for the package check
and the sign-ins: with the defaults, 18 + 30 + 7 = 55.

No Store call in the submit step waits past `submit-minutes`. The last 360
seconds of it are kept for the commit and its read-backs, and the step sends
nothing to the Store API unless at least 60 seconds are left before that
reserve (so `submit-minutes` is at least 8). The submission id and how to check it by hand are printed
before the commit request is sent, and again if the commit gets no answer, so
they are in the log even if the job is cancelled later.

## targetPublishMode=Manual

The action does not set the publish mode. A new submission is a clone of the
app's last published submission, so it carries that submission's
`targetPublishMode`, and the field compare stops the run if the service
changes it during the update.

- `Manual` (recommended): after certification the submission waits until a
  person publishes it in Partner Center. That is the only Partner Center
  action a submission made by this action needs.
- `Immediate` or `SpecificDate`: the read-back step prints a
  `Store publish mode` warning that the submission goes live by itself once it
  passes certification. It is a warning only: the commit has already happened,
  so failing the job would stop nothing.

Do not edit, Submit or delete a submission made by this action in the Partner
Center UI: a draft committed from the UI ships the packages cloned from the
live submission, not the uploaded one.

## Diagnose mode

`mode: diagnose` with `submission-id` reads the app, that submission and the
app's last published submission, each by id, and prints:

- their ids and statuses;
- whether `friendlyName` differs, and which pricing and other fields differ,
  as field paths, never values;
- whether the publish field compare would pass, and on which field it would stop.

It sends only GET requests: while it runs, any other request is refused
before it is sent. It creates, changes, commits and deletes nothing. It still
signs in with the secrets, so run it in the same protected environment.

## Delete-draft mode

`mode: delete-draft` with `submission-id` deletes that one submission, only
while it is the app's pending, uncommitted `PendingCommit` draft and not its
last published submission. It sends GET requests and at most one DELETE of
that id, then counts the draft as deleted only when a GET of it answers HTTP
404 and the app shows no pending submission. Use it for a draft a failed run
left behind, after `diagnose` showed what it is.

## Microsoft Store API limits

What the action works around, and what it cannot do:

- **One pending submission per app.** Create answers HTTP 409 ("the current
  state of the app") while a submission is pending, so the action checks first
  and stops, leaving that submission alone. It never deletes a submission it
  did not create in that run (only `delete-draft`, given an id, deletes one).
- **The first submission is made in Partner Center.** Microsoft requires at
  least one submission of the app made in Partner Center, with the age ratings
  questionnaire answered, before the API can create one. A new submission is a
  copy of the last published submission.
- **Commit is asynchronous.** The commit request only starts processing
  (`CommitStarted`, then `PreProcessing` and certification); the read-back
  waits for a committed status that holds the new package version. An
  unanswered commit is reported as unconfirmed with the id to check, never
  retried.
- **The service rewrites some fields.** `friendlyName` and some pricing fields
  can change after a PUT, and `packageRolloutStatus` and
  `fallbackSubmissionId` are set by Partner Center; these are left out of the
  field compare (pricing is compared by its price values). Every other field
  must come back unchanged.
- **The SAS upload URL is a credential.** It is masked in every message and
  never printed.
- **Only what the API exposes.** The action changes only the package list of
  the cloned submission. Listings, pricing, availability and the publish mode
  stay as they are in the last published submission.
- **The fake Store is a stand-in.** The tests show how the action behaves
  against `scripts/tests/FakeStoreApi.psm1`, a stand-in written to Microsoft's
  API documentation, not against the real service. Its fixtures are made up.

## Tests

```
pwsh -NoProfile -Command "Invoke-Pester -Path scripts/tests -Output Detailed"
```

Pester 5.7.1. The suite covers the submission JSON checks, the full publish,
diagnose and delete-draft flows against the in-memory fake Store, the real
HTTP path against the fake Store served on 127.0.0.1 (including the
`action.yml` step scripts run as written), and static checks on `action.yml`.
`.github/workflows/ci.yml` runs it on Windows and Linux with the runner's
PowerShell, and on Linux with PowerShell 7.7.0 (.NET 11, checked against its
release SHA-256), and runs the action itself in `inspect` mode on a
generated package.

## License

[MIT](LICENSE)
