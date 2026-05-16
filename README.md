# Rocket Jobs — install

[Rocket Jobs](https://rocketjobs.ai) turns a generic AI coding agent (Claude Code, Codex, opencode) into a job-application assistant. Installed skills let the agent read tracked roles from your dashboard, generate a tailored resume and cover letter, and drive your browser through the application form.

This repository is the **public mirror** of the installer and skill bundles. The source of truth lives in a private repo at [`kelvanb97/rocket-jobs`](https://github.com/kelvanb97/rocket-jobs); each release is automatically synced here from there. The mirror exists so you can read what the installer is going to run **before** running it — or skip the installer entirely and place files by hand.

## What gets installed

Two locations on your machine, nothing else:

| Path                                          | Contents                                                                                                                                 |
| --------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `<agent-skills-dir>/rj-apply/SKILL.md`        | Applies to one tracked role end-to-end: builds a tailored resume and cover letter, then drives your browser to fill out the application. |
| `<agent-skills-dir>/rj-health-check/SKILL.md` | Verifies your install: token reachable, skills present, required MCPs registered.                                                        |
| `~/.rocket-jobs/config`                       | Your access token, mode 600.                                                                                                             |
| `~/.rocket-jobs/VERSION`                      | The installed release tag. Used to detect updates.                                                                                       |

`<agent-skills-dir>` is where your coding agent loads custom skills from. See the table under [Option 2](#option-2--install-by-hand) for per-agent paths.

There are **no** system services, package installs, sudo prompts, shell-profile edits, or background processes. If the installer or these instructions ever ask for any of those, treat it as a bug and stop.

---

## Option 1 — review, then run the installer

Recommended for most users. Two minutes of verification, then a one-line install.

### 1. Clone this repo and pick the version you want

```bash
git clone https://github.com/rocket-jobs-ai/manual-install
cd manual-install
git tag --list   # see available releases
git checkout <tag>   # e.g. git checkout v0.10.0
```

### 2. Read `install.sh`

```bash
less install.sh
```

It's pure shell, no dependencies beyond `curl`. It only writes inside `~/.rocket-jobs/` and your agent's skills directory.

### 3. Prove this checkout matches what `rocketjobs.ai` will serve you

The trust property of this mirror is that what's in your `git checkout` is **byte-identical** to what production will hand you. Verify it:

```bash
diff <(curl -fsSL https://rocketjobs.ai/install.sh) install.sh
diff <(curl -fsSL https://rocketjobs.ai/skills/manifest.json) skills/manifest.json
for f in skills/rj-*/SKILL.md; do
  diff <(curl -fsSL "https://rocketjobs.ai/${f#skills/}") "$f" \
    || echo "MISMATCH: $f"
done
```

Silent output on all three = you're safe. Any printed diff = the mirror is stale or production is — stop and report it via your dashboard.

### 4. Run

Once you've verified the bytes, you can install equivalently from either source:

```bash
# from your verified local clone:
./install.sh --agent=claude-code --token=<your-uuid>

# or from the live URL (you've already proven they're identical):
curl -fsSL https://rocketjobs.ai/install.sh | bash -s -- \
  --agent=claude-code \
  --token=<your-uuid>
```

Supported `--agent` values: `claude-code`, `codex`, `opencode`. Find your access token in the Rocket Jobs dashboard under **Settings → Access tokens**.

Prefer not to put the token on the command line? Pass it via env:

```bash
RJ_TOKEN=<your-uuid> ./install.sh --agent=claude-code
```

---

## Option 2 — install by hand

Use this if you'd rather not run a shell script at all, or if you're using a coding agent the installer doesn't recognize.

### 1. Save your access token

```bash
mkdir -p ~/.rocket-jobs
umask 077
cat > ~/.rocket-jobs/config <<EOF
{"access_token":"<your-uuid>","created_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
chmod 600 ~/.rocket-jobs/config
```

### 2. Copy the skill bundles into your agent's skills directory

Each skill is a directory containing a single `SKILL.md`. Copy every `skills/rj-*` directory from this repo to your agent's skills location.

| Agent        | Skills directory                                                                                                                                                                                                                                        |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Claude Code  | `~/.claude/skills/`                                                                                                                                                                                                                                     |
| Codex        | `~/.codex/skills/`                                                                                                                                                                                                                                      |
| opencode     | `~/.opencode/skills/`                                                                                                                                                                                                                                   |
| Other agents | Consult your agent's documentation for where it loads custom skills, system prompts, or instructions from. The `SKILL.md` files are agent-agnostic markdown — they don't depend on any Claude-specific features and any LLM-driven agent can read them. |

Example for Claude Code:

```bash
mkdir -p ~/.claude/skills
cp -R skills/rj-apply skills/rj-health-check ~/.claude/skills/
```

### 3. Record the installed version (optional but recommended)

If you ever run `install.sh` later, it uses this file to decide whether you're up to date.

```bash
echo "<tag-you-installed>" > ~/.rocket-jobs/VERSION
# e.g. echo "0.10.0" > ~/.rocket-jobs/VERSION
```

### 4. Verify

Open your agent and run `/rj-health-check`. It should report **PASS** along with the installed version, your agent name, and the skills it found.

---

## Updating

To pick up a new release:

- **Installer path:** re-run `./install.sh --agent=… --token=…` (or the `curl … | bash` form). It compares the local `~/.rocket-jobs/VERSION` against the published manifest and only re-downloads if there's a change.
- **Manual path:** `git pull` and `git checkout <new-tag>` in your local mirror, recopy the skill directories, update `~/.rocket-jobs/VERSION`.

## Uninstalling

```bash
rm -rf ~/.rocket-jobs
rm -rf ~/.claude/skills/rj-*       # adjust path to match your agent
```

That's everything. No further state lives on your machine.

## Supported agents

The installer auto-maps these:

- **Claude Code** (`claude-code`) — Anthropic's CLI.
- **Codex** (`codex`) — OpenAI's CLI.
- **opencode** (`opencode`) — community CLI agent.

For any other agent, follow Option 2 and consult that agent's docs for where to place skills.

## Reporting drift

If a `diff` in step 3 of Option 1 shows differences, the mirror and production are out of sync — that's a bug on our side, not yours. Report it via your dashboard so we can investigate before anyone else trusts a stale checkout.
