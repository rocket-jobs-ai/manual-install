---
name: rj-apply
description: >
    Apply to one tracked role end-to-end. Generates a tailored resume
    and cover letter, drives Chrome through the Playwright MCP to fill
    out the application form, and pauses for your confirmation before
    submitting. Pass the role ID from your Rocket Jobs dashboard, e.g.
    rj-apply <role-id>.


    Triggers: "rj-apply", "apply to role", "submit application".
user-invocable: true
---

# rj-apply

**Skill invocation syntax.** This file names skills bare — `rj-apply`,
`rj-health-check`. When you invoke one or tell the user to run it, use
**your** agent's own syntax: Claude Code prefixes a `/`, Codex a `$`,
OpenCode and others use the bare name. Never assume `/`.

Apply to a single tracked role end-to-end. Follow these steps in order.

## Argument

Required: an `app.role.id` UUID — the user's tracked role they want to
apply to. The dashboard role page exposes a copy-paste command. If the
user does not provide it, **stop** and tell them to copy the role ID
from the dashboard before re-invoking.

## Invariants

- **Never print the access token.** Read it once, use it via
  `Authorization: Bearer ...` only.
- **Use absolute paths.** Every file path is `$HOME/...` or
  `/tmp/...` with a PID suffix.
- **Never write `~/.rocket-jobs/config`.** The installer owns it.
- **Use the Playwright MCP browser tools (`browser_*`).** Never spawn
  `node`, never write Playwright scripts to `/tmp`. If the MCP isn't
  registered, Step D defers to `rj-health-check` — don't duplicate
  the registration flow here.
- **Do not submit until the user explicitly confirms.** The skill
  pauses at Step J and waits for a yes.
- **Do not auto-skip and continue to the next role.** This skill applies
  to one role; if the URL is dead or the form is unworkable, mark the
  role skipped and stop.

## API base URL

All apply calls hit `https://www.rocketjobs.ai/api/agent/apply/...`. One
sibling endpoint, `https://www.rocketjobs.ai/api/agent/signal`, takes the
best-effort UI signals — `open-arcade` first thing in Step 0, `agent-attention`
at each input pause.

## Step 0 — Fire the arcade invite

This step's only job is to broadcast `open-arcade` the instant the skill runs —
before argument validation or any other call — so the dashboard modal pops as
fast as possible. Read only the token and post; don't validate, don't block.
Step A does the real token and argument checks.

```bash
TOKEN=$(grep -oE '"access_token"[[:space:]]*:[[:space:]]*"[^"]+"' \
        "$HOME/.rocket-jobs/config" 2>/dev/null \
        | sed 's/.*"\([^"]*\)"$/\1/')
curl -sS -o /dev/null --max-time 5 -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Skill-Name: rj-apply" \
  -H 'Content-Type: application/json' \
  -d '{"kind":"open-arcade"}' \
  "https://www.rocketjobs.ai/api/agent/signal" 2>/dev/null || true
```

## Step A — Read the access token and validate the argument

```bash
ROLE_ID="$1"
if [ -z "$ROLE_ID" ]; then
  cat <<'EOF'
rj-apply needs a role ID.

Open the role in the Rocket Jobs dashboard and copy the apply command
from the role detail page — it's already formatted for your agent —
then re-invoke with that role ID.
EOF
  exit 0
fi

CONFIG="$HOME/.rocket-jobs/config"
if [ ! -f "$CONFIG" ]; then
  cat <<'EOF'
No Rocket Jobs config found at ~/.rocket-jobs/config.

Run the installer first (copy the command from
https://rocketjobs.ai/onboarding/install) — it saves the access token
to that file, and then this skill will work.
EOF
  exit 0
fi

TOKEN=$(grep -oE '"access_token"[[:space:]]*:[[:space:]]*"[^"]+"' "$CONFIG" \
        | sed 's/.*"\([^"]*\)"$/\1/')

if ! printf '%s' "$TOKEN" \
     | grep -qiE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
  echo "Config file is present but the access token inside it is malformed."
  echo "Re-run the installer to write a fresh one."
  exit 0
fi

SKILL_VERSION=$(cat "$HOME/.rocket-jobs/VERSION" 2>/dev/null || echo "unknown")
API_BASE="https://www.rocketjobs.ai/api/agent/apply"
DOC_DIR="$HOME/.rocket-jobs/applications/$ROLE_ID"
mkdir -p "$DOC_DIR"
```

Set `BODY` and `HDRS` paths for each curl call so neither the headers
nor body are printed to the transcript:

```bash
hdrs() { printf "/tmp/rj-apply-%s-%s-h" "$$" "$1"; }
body() { printf "/tmp/rj-apply-%s-%s-b" "$$" "$1"; }

# Best-effort UI signal to the user's dashboard — pops a modal while the agent
# works (open-arcade) or when it needs input (agent-attention). Fire-and-forget:
# it never blocks the flow, failures are swallowed, and the dashboard need not
# be open for the run to succeed.
signal() {
  curl -sS -o /dev/null --max-time 5 -X POST \
    -H "Authorization: Bearer $TOKEN" \
    -H "X-Skill-Name: rj-apply" \
    -H "X-Skill-Version: $SKILL_VERSION" \
    -H 'Content-Type: application/json' \
    -d "{\"kind\":\"$1\"}" \
    "https://www.rocketjobs.ai/api/agent/signal" 2>/dev/null || true
}
```

## Step B — Fetch the role context

```bash
HTTP=$(curl -sS -o "$(body B)" -D "$(hdrs B)" -w "%{http_code}" \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Skill-Name: rj-apply" \
  -H "X-Skill-Version: $SKILL_VERSION" \
  "$API_BASE/context/$ROLE_ID")
echo "context:$HTTP"
```

Status handling:

| Status | Action |
| ------ | ------ |
| `200`  | Parse the JSON body. Continue. |
| `401`  | Token rejected. Tell the user to re-run the installer. Stop. |
| `404`  | Role not found in the user's tracker. Tell the user to add it on the dashboard first. Stop. |
| `5xx`  | API error. Print status. Stop. |

The 200 response shape is:

```
{
  "ok": true,
  "data": {
    "role": { id, title, url, description, location, locationType, salaryMin, salaryMax, source, status, ... },
    "company": { name, website, industry, size, stage, ... },
    "profile": { fullName, phone, address, location, currentJobTitle, summary, skills, links, salaryMin, salaryMax, desiredSalary, startDateWeeksOut, ... },
    "workExperience": [ { company, title, startDate, endDate, type, summary, highlights }, ... ],
    "education": [ { degree, field, institution }, ... ],
    "certifications": [ { name, issuer, issueDate, expirationDate, url }, ... ],
    "eeo": { gender, ethnicity, veteranStatus, disabilityStatus, workAuthorization, requiresVisaSponsorship },
    "identity": { email }
  }
}
```

Save the `data` object. You will reuse it in every later step. Set
`URL` from `data.role.url`. If `URL` is null, tell the user the role
has no URL and stop.

### Enforce skill version before continuing

The context response carries a server-built update message in its headers
(already saved to `$(hdrs B)`). Read it once, here — do not re-check on
later calls:

```bash
UPDATE_MSG=$(grep -i '^x-skill-update-message:' "$(hdrs B)" \
             | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r\n')
```

If `UPDATE_MSG` is non-empty, the skills are out of date and this is a hard
stop. Do **not** create the draft, generate documents, or open the browser.
Print `UPDATE_MSG` to the user **verbatim** — it names both versions and
links to the dashboard page with the one-line update command — then stop.

**Never run the update yourself.** Skills do not execute the installer or any
`curl … | bash`; the user runs it from their own terminal after opening the
link. If `UPDATE_MSG` is empty, continue.

## Step C — Display the role and confirm

Show the user:

- Role: `{title}` at `{company.name}`
- Location: `{location}` (`{locationType}`)
- Salary: `{salaryMin} – {salaryMax}` (omit if both null)
- URL: `{url}`

This is the first pause for input, so fire the attention signal before
asking — the user may have kicked off the run and stepped away:

```bash
signal agent-attention
```

Ask: "Apply to this role? (yes / no)". **Wait for the user.** If they
decline, stop here without touching state.

## Step D — Confirm the Playwright MCP is reachable

The skill drives Chrome through a registered Playwright MCP server.
Do **not** run `npx playwright install`, do **not** spawn `node`,
do **not** write Playwright scripts to disk.

You — the agent running this skill — know whether the Playwright MCP
(`browser_*` tools) is registered for you. If it is, continue to
Step E.

If the Playwright MCP is **not** registered for you, dependency
setup belongs to `rj-health-check`, not this skill. Tell the user:

> The Playwright MCP server isn't registered for this agent. Run
> `rj-health-check` to register it, then re-invoke `rj-apply
> <role-id>` once your agent has reloaded the new MCP.

Stop. Do not duplicate the registration flow here — `rj-health-check`
owns dependency setup so this skill (and others) can assume it.

## Step E — Create the draft application

Records the attempt before navigating, so the row exists even if the
user closes mid-flow.

```bash
HTTP=$(curl -sS -o "$(body E)" -D "$(hdrs E)" -w "%{http_code}" \
  -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Skill-Name: rj-apply" \
  -H "X-Skill-Version: $SKILL_VERSION" \
  -H 'Content-Type: application/json' \
  -d "{\"roleId\":\"$ROLE_ID\",\"notes\":\"rj-apply attempt\"}" \
  "$API_BASE/application")
echo "application:$HTTP"
```

The endpoint is idempotent: re-running on the same role returns the
existing application (and its documents, if any).

Parse out `applicationId`, `resumePath`, `coverLetterPath`. Save
`APPLICATION_ID`. If `resumePath` and `coverLetterPath` are both
non-null, jump to Step G (download).

## Step F — Generate documents (only if missing)

If the previous step returned null paths, optionally check Storage
first to confirm:

```bash
curl -sS -o "$(body F-list)" \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Skill-Name: rj-apply" \
  -H "X-Skill-Version: $SKILL_VERSION" \
  "$API_BASE/documents?roleId=$ROLE_ID"
```

If the listing already shows a resume + cover letter, the previous
generation produced them but the application row is stale. Generate
again to be safe — the upload uses `upsert: true`.

Generation is long-running (30–120s):

```bash
HTTP=$(curl -sS --max-time 180 -o "$(body F)" -D "$(hdrs F)" -w "%{http_code}" \
  -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Skill-Name: rj-apply" \
  -H "X-Skill-Version: $SKILL_VERSION" \
  -H 'Content-Type: application/json' \
  -d "{\"applicationId\":\"$APPLICATION_ID\"}" \
  "$API_BASE/documents/generate")
echo "generate:$HTTP"
```

A `200` returns `{ data: { resumePath, coverLetterPath } }`. On any
non-200, surface the body's `error` field to the user and stop. The
draft row is intact for retry.

**Quota exhausted (`402` with `error.code = "QUOTA_EXCEEDED"`)**: the
user has hit their monthly application cap. The body looks like:

```
{ "ok": false, "error": {
  "code": "QUOTA_EXCEEDED",
  "message": "You've used all 30 applications on the free plan this cycle. Upgrade at https://rocketjobs.ai/dashboard/account to keep applying.",
  "actionType": "apply",
  "plan": "free",
  "used": 30,
  "limit": 30,
  "periodEnd": "2026-06-01T00:00:00Z"
} }
```

Print the `error.message` to the user verbatim and stop. Do not retry.
The draft application row stays, so they can resume after upgrading or
after the period resets at `error.periodEnd`.

## Step G — Download documents to local disk

The agent runs locally; Storage is in the cloud. Mint signed URLs and
curl them down:

```bash
HTTP=$(curl -sS -o "$(body G)" -D "$(hdrs G)" -w "%{http_code}" \
  -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Skill-Name: rj-apply" \
  -H "X-Skill-Version: $SKILL_VERSION" \
  -H 'Content-Type: application/json' \
  -d "{\"applicationId\":\"$APPLICATION_ID\"}" \
  "$API_BASE/documents/download")
echo "download:$HTTP"
```

The 200 body looks like:

```
{ "data": {
  "resumeUrl": "https://...signed...",
  "resumeFilename": "Jane Doe Resume.docx",
  "coverLetterUrl": "https://...signed...",
  "coverLetterFilename": "Jane Doe Cover Letter.docx"
} }
```

Curl each URL to disk, preserving the human-readable filename so the
ATS form sees an applicant-style filename. The download lands in
`~/.rocket-jobs/applications/<roleId>/` (audit trail).

```bash
RESUME_LOCAL="$DOC_DIR/$RESUME_FILENAME"
COVER_LOCAL="$DOC_DIR/$COVER_LETTER_FILENAME"
curl -sS -o "$RESUME_LOCAL" "$RESUME_URL"
curl -sS -o "$COVER_LOCAL" "$COVER_LETTER_URL"
```

**Stage docs into a Playwright-reachable path.** The Playwright MCP
sandboxes `browser_file_upload` to a configured `allowedRoots` list,
which by default only includes the current working directory and its
`.playwright-mcp/` subdir. Copy the docs into `$PWD/.playwright-mcp/`
so the upload succeeds without asking the user to reconfigure their
MCP:

```bash
STAGE_DIR="$PWD/.playwright-mcp"
mkdir -p "$STAGE_DIR"
RESUME_STAGED="$STAGE_DIR/$RESUME_FILENAME"
COVER_STAGED="$STAGE_DIR/$COVER_LETTER_FILENAME"
cp "$RESUME_LOCAL" "$RESUME_STAGED"
cp "$COVER_LOCAL" "$COVER_STAGED"
```

Use `$RESUME_STAGED` / `$COVER_STAGED` (absolute paths) for
`browser_file_upload`. The canonical copies in `$DOC_DIR` stay as the
audit trail.

If `browser_file_upload` still rejects the staged path with an
"outside allowed roots" error, the user has a non-default MCP config.
Tell them to add `$HOME/.rocket-jobs/applications` (or the staging
dir) to the Playwright MCP `allowedRoots` setting and re-invoke the
skill.

## Step H — Open the browser and navigate

Drive the browser through the Playwright MCP. Each tool call is
first-class — no temp scripts, no stdout JSON parsing.

1. Call `browser_navigate` with `URL`.
2. Call `browser_snapshot` (interesting accessibility tree only) and
   read it directly.
3. **Legitimacy check** — decide from the snapshot:
   - **Legitimate**: a job listing, an ATS platform (Greenhouse, Lever,
     Workday, Ashby, BambooHR, etc.), a company career page, or a job
     board page (LinkedIn, Indeed, etc.).
   - **Illegitimate**: parked domain, default hosting placeholder,
     ad/SEO-farm page with no job content, payment-required scam,
     unrelated content (e-commerce, gaming, crypto), broken page
     (404, blank, 5xx), or phishing indicators (mismatched branding,
     SSN/bank-detail asks upfront).
   - **When in doubt, lean legitimate.** The user reviews before
     submit.
4. **If illegitimate**, mark the role skipped and **stop** (do not
   loop to a next role — this skill applies to one role only):

   ```bash
   curl -sS -o /dev/null -X POST \
     -H "Authorization: Bearer $TOKEN" \
     -H "X-Skill-Name: rj-apply" \
     -H "X-Skill-Version: $SKILL_VERSION" \
     -H 'Content-Type: application/json' \
     -d "{\"roleId\":\"$ROLE_ID\",\"reason\":\"<short reason>\"}" \
     "$API_BASE/skip"
   ```

   Tell the user the role was marked skipped and the reason. Stop.
5. **If the page is a job listing** rather than the application form
   itself, find the "Apply" affordance in the snapshot and click it
   with `browser_click`. Then snapshot again. Repeat until you reach
   the form (one snapshot/click per loop iteration; do not chain
   guesses).
6. **Login walls**: if the snapshot shows a sign-in form, fire
   `signal agent-attention` (best-effort), then tell the user "Please log
   in in the browser window — say 'continue' when ready." Wait for the
   user. The MCP's persistent profile carries the session forward to
   subsequent runs.
7. **CAPTCHA**: same pattern — fire `signal agent-attention`, tell the
   user to solve it, wait for "continue".

## Step I — Fill the form

Work in a snapshot → decide → act → snapshot loop. Two or three fields
per pass keeps the model from drifting.

### Reading the page

- `browser_snapshot` — accessibility tree of interactive elements
  with `ref` attributes. Default tool.
- Optional: `browser_run_code` with `page.evaluate(...)` only when you
  need to scroll a section into view, expand a collapsed accordion,
  or read a non-accessible attribute. Avoid for normal field reads.

### Filling the page

- `browser_type` — text inputs (single field).
- `browser_fill_form` — batch fill when the snapshot gives a clear
  refs-and-values map. **Only use `type: "textbox"` or `type:
  "checkbox"` here.** `type: "combobox"` only works on native
  `<select>` elements; almost every modern ATS (Greenhouse, Lever,
  Workday, Ashby) uses React-Select, where `browser_fill_form` will
  throw "Element is not a `<select>` element" and stop the batch.
- `browser_select_option` — native `<select>` only. Same caveat as
  above; will fail on React-Select.
- **Custom comboboxes / React-Select dropdowns** (the default
  pattern):
    1. `browser_click` on the `Toggle flyout` button next to the
       combobox to open the option list.
    2. `browser_snapshot` with `target` set to the combobox group ref
       to read the option refs without snapshotting the whole page.
    3. `browser_click` the matching option ref.
    Do *not* try to `browser_type` into a React-Select input as a
    shortcut — it sets the filter text but does not commit a
    selection, and the form will fail validation with "This field
    is required". Always click a real option.
- `browser_click` — radios, checkboxes, "Next" / "Continue".
- `browser_file_upload` — pass the **staged** absolute paths from
  Step G (`$RESUME_STAGED`, `$COVER_STAGED`), not the canonical
  `$DOC_DIR` paths. The canonical paths live outside the Playwright
  MCP's `allowedRoots` and will be rejected.
- Prefer `getByRole`, `getByLabel`, `getByPlaceholder` semantics over
  CSS selectors when you have the choice. They survive minor DOM
  shifts.

### Field mappings (pull from the context bundle saved in Step B)

- Full name → `profile.fullName`
- Email → `identity.email`
- Phone → `profile.phone`
- Address → `profile.address`
- City / location → `profile.location`
- LinkedIn / GitHub / portfolio → entries in `profile.links`
- Current title → `profile.currentJobTitle`
- Professional summary → `profile.summary`
- Work history → `workExperience` (one entry per row)
- Education → `education`
- Certifications → `certifications` (only if the form asks)
- Salary → `profile.salaryMin` / `profile.salaryMax` /
  `profile.desiredSalary`
- Resume upload → `browser_file_upload` with `$RESUME_STAGED`
- Cover letter upload → `browser_file_upload` with `$COVER_STAGED`
- EEO answers — gender, ethnicity, veteran status, disability status:
  `eeo.*`. If the value is null, select "Decline to self-identify"
  (or the closest equivalent).
- Work authorization → `eeo.workAuthorization`. Visa sponsorship →
  `eeo.requiresVisaSponsorship` (boolean). If both are null, ask the
  user.
- Start date — compute by adding `profile.startDateWeeksOut` weeks to
  today.

### Hardcoded fallbacks for common questions

When the bundle doesn't cover a field, use these defaults. Ask the
user only for genuinely unusual or role-specific questions.

- "How did you hear about this role?" — infer from `role.source`,
  else "Online job board".
- "Referred by employee?" — "No".
- "Non-compete agreement?" — "No".
- "Previously employed here?" — "No".
- "Professional references?" — "Available upon request".
- "Employment type?" — infer from `role.type`, else "Full-Time".

For free-text questions ("Why do you want to work here?", "Tell us
about a relevant project"): generate a concise 2–3 sentence response
grounded in `role.description`, `company.*`, and the most relevant
items in `workExperience` / `education`. Tailor to the role. Keep
professional.

### Multi-page forms

Workday and friends spread the form across multiple pages:

1. Fill all visible fields on the current page.
2. `browser_snapshot` to confirm.
3. `browser_click` on "Next" / "Continue" / equivalent.
4. Repeat until you reach the review/submit page.

## Step J — Pre-submission review

Take a final `browser_snapshot` and write a one-screen summary back to
the user from the filled values plus the context bundle:

```
Filled out for {company.name}:
- Name        : {profile.fullName}
- Email       : {identity.email}
- Phone       : {profile.phone}
- Resume      : {RESUME_LOCAL}
- Cover letter: {COVER_LOCAL}
- Work auth   : {eeo.workAuthorization or "decline"}
- Start date  : {computed start date}
... (cover the major sections you filled)
```

This is the main place the user gets pulled back after wandering off during
generation, so fire the attention signal before prompting:

```bash
signal agent-attention
```

Then say: "The application form is filled out in the browser window.
Please review it. Should I submit? (yes / no)"

**Wait for an explicit yes.** If the user says no, jump to the
"declined" branch in Step L.

## Step K — Submit

Only on explicit "yes":

1. From the latest snapshot, find the submit affordance — `role=button`
   with name matching `/submit|apply|send/i`, picking the most
   specific match.
2. `browser_click` that ref.
3. Wait ~4 seconds (poll a follow-up snapshot or use the MCP's wait
   helper) for navigation to a confirmation page.
4. `browser_snapshot` again to confirm a success/confirmation surface
   rendered.

If the click target isn't found, snapshot, describe what's visible,
ask the user to identify the submit element, and try again. Do not
fabricate selectors or refs.

## Step L — Update records

On a successful submit:

```bash
HTTP=$(curl -sS -o "$(body L)" -D "$(hdrs L)" -w "%{http_code}" \
  -X PATCH \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Skill-Name: rj-apply" \
  -H "X-Skill-Version: $SKILL_VERSION" \
  -H 'Content-Type: application/json' \
  -d "{\"applicationId\":\"$APPLICATION_ID\"}" \
  "$API_BASE/submit")
echo "submit:$HTTP"
```

A 200 marks the application `submitted` and the role `applied`. Any
non-200: do NOT report success — show the error and let the user
decide whether to retry the PATCH.

If the user declined to submit (Step J → no):

```bash
curl -sS -o /dev/null -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Skill-Name: rj-apply" \
  -H "X-Skill-Version: $SKILL_VERSION" \
  -H 'Content-Type: application/json' \
  -d "{\"roleId\":\"$ROLE_ID\",\"reason\":\"User declined to submit\"}" \
  "$API_BASE/skip"
```

The application stays as a draft so the user can pick it up later.

## Step M — Summary

Print:

```
rj-apply complete

  Role          {title} at {company.name}
  Application   {APPLICATION_ID}
  Status        submitted   (or  draft, declined)
  Resume        {RESUME_LOCAL}
  Cover letter  {COVER_LOCAL}
```

## Cleanup

Remove curl temp files and the staged doc copies. None of them
contain the token (the curl helpers write headers and bodies
separately, the auth header lives in env only):

```bash
rm -f /tmp/rj-apply-$$-* 2>/dev/null
rm -f "$RESUME_STAGED" "$COVER_STAGED" 2>/dev/null
```

The MCP-managed Chrome profile and the canonical downloads in
`~/.rocket-jobs/applications/<roleId>/` stay on disk so the next
rj-apply run reuses sessions and so the user can audit what was
uploaded.

## Failure handling

| Situation                                     | Action                                                                                         |
| --------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| No role ID arg                                | Tell the user how to copy one from the dashboard. Stop.                                        |
| `~/.rocket-jobs/config` missing or malformed  | Tell the user to run the installer. Stop.                                                      |
| 401 from any API call                         | Token rejected. Tell the user to re-run the installer. Stop.                                   |
| 404 on `/context/$ROLE_ID`                    | Role isn't in the user's tracker. Tell the user to add it on the dashboard. Stop.              |
| Playwright MCP not registered                 | Tell the user to run `rj-health-check` (which owns dependency setup), then re-invoke. Stop. |
| Page is illegitimate                          | Mark the role skipped via `/skip`, tell the user the reason, stop.                             |
| Login wall                                    | Ask the user to log in in the browser window, wait for "continue".                             |
| CAPTCHA                                       | Ask the user to solve it, wait for "continue".                                                 |
| Doc generation fails                          | Surface the API error message. Draft row stays. User can retry by re-invoking rj-apply.        |
| 402 `QUOTA_EXCEEDED` on doc generation        | Print `error.message` verbatim (includes the upgrade link). Do not retry. Draft row stays.     |
| Form field can't be found                     | Take a snapshot, describe what is visible, ask the user for guidance. Do not guess selectors.  |
| Submit button click failed                    | Same as above — describe, ask, retry.                                                          |
| `/submit` API call fails after browser submit | Do NOT claim success. Report the API error. The user can manually retry the PATCH.             |
