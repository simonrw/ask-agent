# Spec: Support Claude (`claude -p`) as an agent provider

## Problem Statement

Today `ask-agent.nvim` can only drive one coding agent: the Codex CLI. Every part of
the plugin - the command it spawns, the arguments it builds, the prompt wording, and
the "Codex" strings in the statusline and logs - assumes Codex. A user who prefers
Claude Code (or wants to switch per project) has no way to route the same
select-and-instruct workflow through `claude -p`. They would have to fork the plugin
or maintain a second copy.

## Solution

Introduce an agent-provider abstraction. The user picks a provider in `setup()`
(`provider = "codex"` or `provider = "claude"`), and the existing `:AskAgent` workflow
runs through the chosen backend. Codex stays the default, so existing configs keep
working unchanged. Selecting `"claude"` spawns `claude -p` with the workspace as its
working directory and edits auto-accepted, streaming the run into the same statusline
and log window - now labelled "Claude" instead of "Codex".

## User Stories

1. As a Neovim user who prefers Claude Code, I want to set `provider = "claude"` in
   `setup()`, so that `:AskAgent` drives `claude -p` instead of Codex.
2. As an existing Codex user, I want the plugin to default to Codex when I set no
   provider, so that upgrading the plugin does not change my workflow.
3. As a user, I want to select code in visual mode and run `:AskAgent`, so that the
   configured provider edits the selection in place - regardless of which provider I chose.
4. As a Claude user, I want `claude -p` to run with its working directory set to my
   workspace root (git root, else cwd), so that it edits the correct project.
5. As a Claude user, I want Claude to be allowed to apply file edits without an
   interactive permission prompt, so that a non-interactive run can actually change files.
6. As a Claude user, I want the prompt sent over stdin like Codex, so that long
   instructions and selection context are passed reliably without shell-escaping issues.
7. As a Claude user, I want the statusline to show a spinner and a "Claude" label while
   the run is active, so that I can tell an agent is working.
8. As a user, I want the statusline to disappear when the run finishes, so that it does
   not linger.
9. As a Claude user, I want the full Claude response captured in the log window, so that
   I can review what it did via `:AskAgentLogs`.
10. As a user, I want a clear error notification if the chosen provider's CLI is missing
    or exits non-zero, so that I know the run failed and why.
11. As a user, I want to override the provider's command name (e.g. a wrapper script or
    absolute path), so that I can point at a non-default binary.
12. As a user, I want to pass extra provider-specific CLI arguments, so that I can tune
    each backend without a plugin change.
13. As a user, I want to set a model for whichever provider I use, so that I can choose,
    for example, a specific Claude or Codex model.
14. As a Codex user, I want my existing `sandbox`, `codex_cmd`, `model`, and `extra_args`
    settings to keep working, so that nothing regresses.
15. As a user, I want the inline form `:AskAgent <instruction>` to work with either
    provider, so that I can skip the floating prompt regardless of backend.
16. As a user, I want buffers to live-reload as the chosen provider writes files, so that
    I see edits appear without manual reloading.
17. As a user, I want an unknown `provider` value to produce a clear configuration error
    at setup time, so that I catch typos immediately.
18. As a maintainer, I want provider-specific behaviour isolated behind one abstraction,
    so that adding a third provider later touches one table, not the whole file.

## Implementation Decisions

### Provider abstraction (the single seam)

- Introduce a `providers` table keyed by provider name. Each entry is a spec describing
  everything provider-specific:
  - `cmd` - default command name (config-overridable).
  - `label` - display name used in statusline and log strings (`"Codex"` / `"Claude"`).
  - `build_args(root)` - returns the argv (excluding the command itself) for that provider.
- All provider-specific branching lives in this table. The rest of the plugin
  (`run_agent`, statusline, logs, live reload, job lifecycle) is provider-agnostic and
  reads `label` / `cmd` / `build_args` from the selected spec.

### Configuration

- Add `provider` to config defaults, default `"codex"` (back-compat).
- Keep existing Codex keys (`codex_cmd`, `sandbox`, `model`, `extra_args`) working.
- `model` and `extra_args` apply to whichever provider is active.
- Command override: the active provider's `cmd` may be overridden by config. `codex_cmd`
  continues to override the Codex command (back-compat). A parallel key overrides the
  Claude command (e.g. `claude_cmd`).
- On `setup()`, validate `provider` against the known providers; an unknown value raises a
  clear configuration error / error notification rather than failing later at spawn time.

### Codex provider (unchanged behaviour)

- `build_args(root)` produces `exec --sandbox <sandbox> --cd <root> [--model <model>]
  <extra_args...> -`, identical to today. Prompt is piped over stdin.

### Claude provider

- Command: `claude`.
- `build_args(root)` produces: `-p --permission-mode acceptEdits --add-dir <root>
  [--model <model>] <extra_args...>`.
  - `-p` / `--print`: non-interactive print mode.
  - `--permission-mode acceptEdits`: auto-accept file edits (closest parity to Codex's
    `workspace-write` sandbox; other actions still gated). `sandbox` config does not apply
    to Claude.
  - `--add-dir <root>`: grant tool access to the workspace root. The job's `cwd` is also
    set to `root` (as it already is for Codex).
  - `--output-format` is left at the default `text` for v1 (see Out of Scope for
    stream-json).
- Prompt is passed over stdin (works with `-p`), same channel Codex uses, so the existing
  `chansend` + `chanclose(stdin)` flow is reused unchanged.

### Prompt wording

- `build_prompt` is parametrized by the active provider's `label` so the leading line
  reads "...through <label> non-interactive mode" instead of a hardcoded "Codex". The rest
  of the prompt (instruction, focus selection, guidance) is provider-agnostic.

### Statusline and logs

- Replace hardcoded "Codex" literals in statusline text, run-state messages
  ("... started", "... finished successfully", "... failed with exit code N",
  "Failed to start ... job") and the log filetype/labels with the active provider's
  `label`.
- The spinner, truncation, live-reload, log buffer handling, and job lifecycle are
  unchanged and shared across providers.

### Job lifecycle

- Generalize `run_codex` into a provider-agnostic `run_agent(prompt, root)` that reads the
  active provider spec for `cmd` and `build_args`. stdout/stderr streaming, `on_exit`
  handling, error notification, reload timer, and status timer are unchanged.

## Testing Decisions

- Good tests here exercise external behaviour at the highest existing seam - the argv a
  provider builds and the prompt text - not internal job wiring or Neovim UI internals.
  The current suite already tests `build_args`, `build_prompt`, `find_workspace_root`, and
  `statusline` at this level; extend that rather than adding new seams.
- `build_args` tests, one per provider:
  - Codex: assert the existing argv is unchanged (regression guard) with default and with
    a `model` set.
  - Claude: assert argv is `-p --permission-mode acceptEdits --add-dir <root>` and that a
    configured `model` and `extra_args` are appended in the right place.
- Provider selection: assert `provider = "claude"` routes `build_args` to the Claude spec
  and `provider` unset defaults to Codex.
- Config validation: assert an unknown `provider` raises a clear error at `setup()`.
- `build_prompt`: assert the label in the leading line follows the active provider
  (existing prompt-content assertions otherwise hold).
- Statusline: extend the existing running/stopped tests to assert the provider `label`
  appears (e.g. "Claude" when the Claude provider is active).
- Prior art: `tests/ask_agent_spec.lua` - the existing `build_args`, `build_prompt`, and
  `statusline` cases are the templates to follow. Run via the `make test` target.

## Out of Scope

- Live intermediate output for Claude via `--output-format stream-json --verbose`
  (per-provider stdout JSON parsing). v1 uses default `text` output: spinner + generic
  "Claude working" during the run, with the full response captured in logs on exit. This
  is a deliberate follow-up seam.
- Per-invocation provider selection (e.g. `:AskAgentClaude` / a provider arg). v1 is
  global config only.
- Bypassing all permissions for Claude (`--dangerously-skip-permissions`). v1 uses
  `acceptEdits`.
- Auto-detecting which CLI is installed and choosing a provider automatically.
- Any provider beyond Codex and Claude.
- Changing the visual-selection, floating-prompt, or log-window UX.

## Further Notes

- Claude and Codex expose different permission/sandbox models; `sandbox` remains
  Codex-only and is simply ignored by the Claude provider rather than mapped.
- The abstraction is intentionally a small data table so a future third provider is a new
  entry plus its `build_args`, not changes threaded through the file.
- `--add-dir` plus `cwd = root` is intentionally belt-and-suspenders so Claude both starts
  in and is permitted to edit the workspace root.
