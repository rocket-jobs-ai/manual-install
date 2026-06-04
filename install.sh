#!/usr/bin/env bash
# Rocket Jobs skills installer.
#
# Usage:
#   curl -fsSL https://rocketjobs.ai/install.sh | bash -s -- \
#     --agent=claude-code \
#     --token=<uuid>
#
# What it does:
#   - downloads each skill listed in the remote manifest
#   - installs them into the agent's skills directory
#   - records the installed version at ~/.rocket-jobs/VERSION
#   - writes the access token to ~/.rocket-jobs/config (mode 600) so that
#     rj-health-check and later skills can read it
#
# Only touches files under ~/.rocket-jobs/ and the agent's skills dir.
# Only requires curl.

set -euo pipefail

RJ_BASE_URL="${RJ_BASE_URL:-https://rocketjobs.ai}"
RJ_HOME="${HOME:-}/.rocket-jobs"
AGENT=""
TOKEN="${RJ_TOKEN:-}"

log() { printf '[rocket-jobs] %s\n' "$*"; }
err() { printf '[rocket-jobs] error: %s\n' "$*" >&2; }

require_cmd() {
	if ! command -v "$1" >/dev/null 2>&1; then
		err "missing required command: $1"
		exit 1
	fi
}

cleanup_tmp() {
	[ -n "${RJ_TMP_DIR:-}" ] && [ -d "$RJ_TMP_DIR" ] && rm -rf "$RJ_TMP_DIR"
}
trap cleanup_tmp EXIT

# ----------------------------------------------------------------------------
# Agent → skills dir mapping. Add new agents here.
# ----------------------------------------------------------------------------

skills_dir_for_agent() {
	case "$1" in
		claude-code) echo "$HOME/.claude/skills" ;;
		codex)       echo "$HOME/.codex/skills" ;;
		opencode)    echo "$HOME/.opencode/skills" ;;
		other)
			err "the 'other' option has no automated install — every agent stores skills in a different place."
			err "follow the manual install steps in the onboarding UI."
			return 1
			;;
		*)
			err "unknown agent: $1"
			err "supported: claude-code, codex, opencode"
			return 1
			;;
	esac
}

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------

for arg in "$@"; do
	case "$arg" in
		--agent=*) AGENT="${arg#--agent=}" ;;
		--agent)
			err "use --agent=<name>, not --agent <name>"
			exit 2
			;;
		--token=*) TOKEN="${arg#--token=}" ;;
		--token)
			err "use --token=<uuid>, not --token <uuid>"
			exit 2
			;;
		-h|--help)
			cat <<'EOF'
Rocket Jobs installer.

  --agent=<name>    coding agent to install for
                    supported: claude-code, codex, opencode
  --token=<uuid>    your Rocket Jobs access token
                    (also accepted via the RJ_TOKEN env var — recommended,
                    stays out of shell history)

Files written:
  ~/.rocket-jobs/VERSION    installed release tag
  ~/.rocket-jobs/config     {"access_token": "…"} (mode 600)
  <agent-skills-dir>/rj-*/SKILL.md
EOF
			exit 0
			;;
		*)
			err "unknown argument: $arg"
			exit 2
			;;
	esac
done

# ----------------------------------------------------------------------------
# Environment checks
# ----------------------------------------------------------------------------

if [ -z "${HOME:-}" ]; then
	err "\$HOME is not set; cannot continue"
	exit 1
fi

if [ -z "$AGENT" ]; then
	err "missing --agent=<name>; supported: claude-code, codex, opencode"
	exit 2
fi

# Validate token shape early (UUID, case insensitive). A missing token is fine —
# this lets users re-run install.sh to update skills without re-supplying it.
if [ -n "$TOKEN" ]; then
	if ! printf '%s' "$TOKEN" | grep -qiE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
		err "--token must be a UUID; got something else"
		exit 2
	fi
fi

TARGET=$(skills_dir_for_agent "$AGENT") || exit 2

# The agent's home dir (e.g. $HOME/.claude) must already exist — we only create
# the skills/ leaf underneath it. If it's missing, the agent isn't installed
# and installing would orphan files on disk.
AGENT_HOME=$(dirname "$TARGET")
if [ ! -d "$AGENT_HOME" ]; then
	err "$AGENT_HOME not found — is $AGENT installed?"
	exit 1
fi

require_cmd curl

# ----------------------------------------------------------------------------
# Fetch manifest
# ----------------------------------------------------------------------------

MANIFEST=$(curl -fsSL "$RJ_BASE_URL/skills/manifest.json")
if [ -z "$MANIFEST" ]; then
	err "could not fetch manifest from $RJ_BASE_URL/skills/manifest.json"
	exit 1
fi

REMOTE_VERSION=$(
	printf '%s' "$MANIFEST" \
		| grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]*"' \
		| head -n1 \
		| sed 's/.*"\([^"]*\)"$/\1/'
)
if [ -z "$REMOTE_VERSION" ]; then
	err "manifest did not contain a version field"
	exit 1
fi

REMOTE_SKILLS=$(
	printf '%s' "$MANIFEST" \
		| grep -oE '"rj-[a-z0-9-]+"' \
		| sed 's/"//g' \
		| sort -u
)
if [ -z "$REMOTE_SKILLS" ]; then
	err "manifest did not list any rj-* skills"
	exit 1
fi

log "remote version: $REMOTE_VERSION"

LOCAL_VERSION=""
if [ -f "$RJ_HOME/VERSION" ]; then
	LOCAL_VERSION=$(tr -d '[:space:]' < "$RJ_HOME/VERSION")
fi

# ----------------------------------------------------------------------------
# Token write — idempotent; always runs if a token was provided, regardless
# of whether the skills themselves need reinstalling.
# ----------------------------------------------------------------------------

write_token_config() {
	local now
	mkdir -p "$RJ_HOME"
	now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	umask 077
	printf '{"access_token":"%s","created_at":"%s"}\n' "$TOKEN" "$now" \
		> "$RJ_HOME/config"
	chmod 600 "$RJ_HOME/config"
	log "saved access token → $RJ_HOME/config"
}

# ----------------------------------------------------------------------------
# Fast path: already up to date AND every manifest skill is present on disk.
# ----------------------------------------------------------------------------

target_has_all_skills() {
	local name
	for name in $REMOTE_SKILLS; do
		[ -f "$TARGET/$name/SKILL.md" ] || return 1
	done
	return 0
}

if [ -n "$LOCAL_VERSION" ] && [ "$LOCAL_VERSION" = "$REMOTE_VERSION" ] && target_has_all_skills; then
	[ -n "$TOKEN" ] && write_token_config
	log "already on v$REMOTE_VERSION and $AGENT is in place."
	log "nothing to do."
	exit 0
fi

# ----------------------------------------------------------------------------
# Full install / update
# ----------------------------------------------------------------------------

RJ_TMP_DIR=$(mktemp -d -t rj-skills.XXXXXX)
SKILLS_STAGE="$RJ_TMP_DIR/skills"
mkdir -p "$SKILLS_STAGE"

log "downloading skills…"
for name in $REMOTE_SKILLS; do
	mkdir -p "$SKILLS_STAGE/$name"
	curl -fsSL "$RJ_BASE_URL/skills/$name/SKILL.md" \
		-o "$SKILLS_STAGE/$name/SKILL.md"
	log "  • $name"
done

mkdir -p "$TARGET"
for name in $REMOTE_SKILLS; do
	rm -rf "$TARGET/$name"
	mv "$SKILLS_STAGE/$name" "$TARGET/$name"
done
log "installed → $TARGET"

mkdir -p "$RJ_HOME"
printf '%s\n' "$REMOTE_VERSION" > "$RJ_HOME/VERSION"

[ -n "$TOKEN" ] && write_token_config

if [ -z "$LOCAL_VERSION" ]; then
	log "installed Rocket Jobs skills v$REMOTE_VERSION for $AGENT."
else
	log "updated Rocket Jobs skills: v$LOCAL_VERSION → v$REMOTE_VERSION."
fi
