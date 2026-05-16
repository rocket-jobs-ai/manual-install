# Rocket Jobs — manual install mirror

Public mirror of the [Rocket Jobs](https://rocketjobs.ai) installer and skill
bundles. The source of truth lives in the private `kelvanb97/rocket-jobs`
repo; this mirror exists so you can read exactly what
`https://rocketjobs.ai/install.sh` is going to run **before** you run it.

## Verify this checkout matches production

```bash
diff <(curl -fsSL https://rocketjobs.ai/install.sh) install.sh
diff <(curl -fsSL https://rocketjobs.ai/skills/manifest.json) skills/manifest.json
for f in skills/rj-*/SKILL.md; do
  diff <(curl -fsSL "https://rocketjobs.ai/${f#skills/}") "$f" \
    || echo "MISMATCH: $f"
done
```

If every `diff` is silent, this checkout is byte-for-byte what production
will serve.

## Install (after verification)

```bash
./install.sh --agent=claude-code --token=<your-uuid>
```

Supported agents: `claude-code`, `codex`, `opencode`.

## Provenance

- Manifest version: `0.10.0`
- Source commit: `f83adceb686fbed484febb6c33cf451acf69673f`
- Synced at: `2026-05-16T19:36:07Z`
- Skills in this release: `rj-health-check`, `rj-apply`

The installer is intentionally **not** stamped with provenance comments —
adding any in-file metadata would break byte-for-byte diff against the live
response. The git tag `v0.10.0` on this repo is your provenance anchor.
