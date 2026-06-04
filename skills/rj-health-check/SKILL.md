---
name: rj-health-check
description: >
    Verify your Rocket Jobs setup end-to-end — installer ran, access
    token is on disk, your agent can reach the API, and every required
    MCP (currently Playwright) is registered. Reports plan, agent,
    skill version, and an overall PASS/FAIL verdict. Other skills
    assume this passes; if a skill complains that a dependency is
    missing, run /rj-health-check to fix it.


    Triggers: "/rj-health-check", "rj-health-check", "check rocket
    jobs", "verify rocket jobs setup".
user-invocable: true
---

# rj-health-check

This skill is the **single source of truth** for whether the user's
Rocket Jobs setup is healthy. It runs a full dependency audit:

- Skills are installed, the access token is on disk, and the agent
  can reach the API with that token.
- Every required MCP server is registered for the running agent.

Other skills (notably `rj-apply`) **rely on this audit** — they assume
their dependencies are correct and, when they aren't, they defer back
to this skill rather than duplicating the setup flow.

The installer (`install.sh`) already wrote the token to
`~/.rocket-jobs/config`. This skill reads it, audits required MCPs,
posts the audit to the API (so the dashboard's "Test connection" UI
sees the same picture), and reports. It does NOT accept the token as
an argument — if the config isn't on disk, tell the user to run the
installer first.

The verdict is **strict**: any missing dependency or failing check
makes the overall status `UNHEALTHY`. Do not soft-pass. When a
dependency is missing, **short-circuit** — do not run the rest of the
skill or any downstream work after the dependency-install prompt.

## Invariants

Follow these strictly. Read before acting.

- **Never print the access token.** Not in success output, not in error
  messages, not when reading the config file back. Grep/sed it out;
  never `echo` or `cat` the token value.
- **Use absolute paths.** Every file path must be
  `"$HOME/.rocket-jobs/..."` or a `/tmp/...` path with a PID suffix.
  Never `cd`. Never rely on `$PWD`.
- **Never write the config file.** The installer owns that file; if it
  isn't there, the fix is running the installer, not this skill.
- **Respect URL overrides from arguments.** If the invocation arguments
  include a base-URL override (e.g. "use http://localhost:4000 instead
  of https://rocketjobs.ai for API requests"), substitute that base
  URL for every API call below. The default base is
  `https://www.rocketjobs.ai`.

## Step 1 — Read the access token

```bash
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

echo "token:loaded"
```

## Step 2 — Dependency audit (pre-flight)

Before calling the API, audit required MCPs. You — the running agent
— know which MCPs are registered for you.

### Required MCPs

| MCP        | Used by  | Why                                                                 |
| ---------- | -------- | ------------------------------------------------------------------- |
| Playwright | rj-apply | Provides the `browser_*` tools used to drive job-application forms. |

For each required MCP, decide one of `ok` or `missing` based on your
own tool registry. Set a shell variable per MCP, e.g.:

```bash
PLAYWRIGHT_STATUS="ok"      # or "missing"
```

These statuses go into the request body in Step 3 so the server can
build the same verdict and broadcast it to the dashboard UI. Do not
skip the audit and do not assume `ok` — if you are unsure, mark
`missing` and the user will be prompted to install.

## Step 3 — Call the health endpoint

Determine the installed skill version:

```bash
SKILL_VERSION=$(cat "$HOME/.rocket-jobs/VERSION" 2>/dev/null || echo "unknown")
```

Build the request body from the audit results in Step 2:

```bash
REQ_BODY=$(printf '{"dependencies":{"playwright":"%s"}}' "$PLAYWRIGHT_STATUS")
```

POST to `/api/agent/health`, writing headers and body to separate temp
files so neither is printed to the transcript. Use the base URL from
the Invariants section (default `https://www.rocketjobs.ai`, or the
override the user passed in arguments):

```bash
HDRS="/tmp/rj-headers-$$"
BODY="/tmp/rj-body-$$"
HTTP=$(curl -sS -o "$BODY" -D "$HDRS" -w "%{http_code}" \
  -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "X-Skill-Name: rj-health-check" \
  -H "X-Skill-Version: $SKILL_VERSION" \
  -d "$REQ_BODY" \
  https://www.rocketjobs.ai/api/agent/health)
echo "http:$HTTP"
```

The server marks the ping (so the dashboard's "Test connection" UI
unblocks), persists nothing token-related, and broadcasts an event
that includes the audit verdict and any error messages back to the
dashboard. Even an `unhealthy` audit fires the broadcast — that's how
the UI reports the failure instead of just timing out.

## Step 4 — Handle the response

| Status | Action                                                                                                                                              |
| ------ | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `200`  | Parse body. Continue to Step 5.                                                                                                                     |
| `401`  | Token rejected. Tell the user the token is invalid and they should copy a fresh one from rocketjobs.ai/onboarding, then re-run the installer. Stop. |
| `5xx`  | API is down. Print the status code and tell the user to retry later. Stop.                                                                          |
| other  | Print the status and exit with an actionable message.                                                                                               |

Parse the 200 response without `jq` if it's not installed:

```bash
PLAN=$(grep -oE '"plan"[[:space:]]*:[[:space:]]*"[^"]*"' "$BODY" \
       | sed 's/.*"\([^"]*\)"$/\1/')
AGENT=$(grep -oE '"agent"[[:space:]]*:[[:space:]]*"[^"]*"' "$BODY" \
        | sed 's/.*"\([^"]*\)"$/\1/')
STATUS=$(grep -oE '"status"[[:space:]]*:[[:space:]]*"[^"]*"' "$BODY" \
         | sed 's/.*"\([^"]*\)"$/\1/')
```

`STATUS` is `healthy` or `unhealthy` — it mirrors what the dashboard
just received over the broadcast. The `errors[]` array in the body is
the same set you'll print in the summary; you can also print them
verbatim with:

```bash
ERRORS=$(grep -oE '"errors"[[:space:]]*:[[:space:]]*\[[^]]*\]' "$BODY" \
         | sed 's/.*\[\(.*\)\]/\1/' | tr -d '"')
```

## Step 5 — Surface update availability

Read the latest version from the response headers:

```bash
LATEST=$(grep -i '^x-skill-latest-version:' "$HDRS" \
         | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r\n')
SEVERITY=$(grep -i '^x-skill-update-severity:' "$HDRS" \
           | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r\n')
```

Decision table:

| `LATEST` vs `SKILL_VERSION` | `SEVERITY`            | Behavior                                                                                          |
| --------------------------- | --------------------- | ------------------------------------------------------------------------------------------------- |
| equal or `LATEST` empty     | —                     | No update message. Skip the rest of this step.                                                    |
| different                   | `required`            | Print a blocking warning. Offer to run the update (see below). Stop at Step 7 summary either way. |
| different                   | `recommended` / other | Print the available version. Offer to run the update (see below). Continue.                       |

### Offer to run the update

Tell the user the new version is available, then ask **verbatim**:

> An update is available (`<SKILL_VERSION>` → `<LATEST>`). Want me to
> run the install command now? (yes / no)

**Wait for an explicit yes.** If the user says yes, run:

```bash
curl -fsSL https://rocketjobs.ai/install.sh | bash -s -- --agent="$AGENT"
```

`AGENT` is the value parsed from the API response in Step 4. The
installer re-uses the existing `~/.rocket-jobs/config`, so no token is
needed on a re-run.

If the user says no (or anything other than yes), print the command
for them to run manually:

```
curl -fsSL https://rocketjobs.ai/install.sh | bash -s -- --agent=<their-agent>
```

Do not run the install command without an explicit yes in this
session — past approval does not carry over.

## Step 6 — Short-circuit on missing dependency

If `STATUS` is `unhealthy` (i.e. any required MCP came back `missing`
in Step 2), this is a hard stop:

1. Print the summary from Step 7 with the missing dep marked
   `missing`. The dashboard already shows the same error from the
   broadcast.
2. Ask the user about installing the missing MCP (substitute the MCP
   name and server command for whichever entry is missing):

    > The Playwright MCP server isn't registered for this agent. I can
    > register it for you at the user/global scope using
    > `npx -y @playwright/mcp@latest` as the server command.
    >
    > Install it now? (yes / no)

    - **Yes** → register the MCP at user/global scope using **whatever
      mechanism your harness exposes** (its CLI's `mcp add` subcommand,
      editing its MCP config file, etc.). Do not bake in commands or
      paths specific to one agent. The server command to register is:

        ```
        npx -y @playwright/mcp@latest
        ```

        Then tell the user the MCP was registered and that they should
        reload their agent according to its own reload behavior and
        re-invoke `/rj-health-check`.

    - **No** → leave the dep missing.

3. **Stop after the user replies.** Do not run downstream skills, do
   not retry the API call, do not "wait and check again" — the next
   `/rj-health-check` invocation is the next attempt. Other skills
   (e.g. `rj-apply`) must defer to this skill rather than retrying
   themselves.

If the registration call fails (CLI not on PATH, network error,
permission error, unknown harness mechanism), surface the exact error
and stop.

## Step 7 — Summary

Print a summary in this exact shape (substituting real values). Do not
include the token:

```
Rocket Jobs — Setup Check

  Access token    ok
  API connection  ok
  Agent           <AGENT>
  Plan            <PLAN>
  Skill version   <SKILL_VERSION><update-note-if-any>

  Dependencies
    Playwright    <ok | missing | pending reload>

  Status: <HEALTHY | UNHEALTHY>
```

The verdict matches the server's `STATUS` field exactly. `Status:
HEALTHY` only when **every** check above is `ok` (token, API, and each
required MCP). Any `missing` or `pending reload` → `Status:
UNHEALTHY`, followed by a one-line follow-up telling the user the
action they need to take (e.g. "Reload your agent and re-run
`/rj-health-check`.").

Stop after the summary. Do not suggest onboarding next steps — the
dashboard handles those — but the action follow-up for unhealthy
results is fine; it directs the user to fix the gap.

## Cleanup

Remove the temp files. The body may contain account metadata but never
the token:

```bash
rm -f "$HDRS" "$BODY"
```

## Failure handling summary

| Situation                          | What to do                                                                                                                                                                                                                 |
| ---------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `curl` fails with non-zero exit    | Network error. Print the exit code and a retry hint. Do not modify state. Overall status `UNHEALTHY`.                                                                                                                      |
| `$HOME` not set                    | Print "HOME is not set — cannot continue." Stop.                                                                                                                                                                           |
| `~/.rocket-jobs/config` missing    | Tell the user to run the installer; it writes that file. Stop. Overall status `UNHEALTHY`.                                                                                                                                 |
| Config present but token malformed | Tell the user to re-run the installer to write a fresh token. Stop. Overall status `UNHEALTHY`.                                                                                                                            |
| Required MCP not registered        | Mark `missing` in the request body so the server broadcasts the failure. Short-circuit per Step 6. Offer to register at user/global scope using the running agent's MCP mechanism. Either way, overall status `UNHEALTHY`. |
