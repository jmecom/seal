# Seal

Seal is a small Neovim interface for a real agent session. It supports Codex app-server and ACP agents, including Gemini CLI with Gemini 3.8 Flash.

Press one key, enter a prompt, and Seal routes it in one of three ways:

- A normal prompt goes unchanged to one persistent Codex thread and shows a spinner and prompt summary at the originating cursor while it runs. When app-server requests approval for a native Codex patch, Seal opens a multi-file diff before answering. `:SealChat` shows the persisted conversation in a read-only Markdown buffer.
- `targeted:` and `refactor:` use that same thread as bounded patch turns and leave a spinner and prompt summary at the originating cursor while they run. Codex may inspect the repository, then proposes one reviewed patch and stops after app-server applies it. These turns do not run tests, builds, linters, or formatters.
- `fun:`, `type:`, `class:`, and other declaration prefixes use read-only turns in the same conversation. Each cursor gets a spinner and prompt summary above its line while Codex works, then an inline declaration preview.

You can submit several prompts immediately. On each project thread, Seal runs the model turns in submission order, one at a time, so every request and result becomes context for the next one. Progress appears on a virtual line above the originating code, so the spinner and prompt summary never shift code sideways or change the buffer. This includes agent startup; once connected, only the request that owns the current turn animates, while queued markers are static. Collocated requests share one marker with a count and remain independently addressable, newest first.

The selected agent owns the agent loop, tools, and compaction. Seal keeps one session per project root in the current Neovim process. Codex is the default backend; its behavior is described below. ACP differences are covered in the next section.

## Requirements

- Neovim 0.11 or newer
- A Tree-sitter parser only if declaration validation is explicitly enabled
- For Codex: Go 1.23 or newer for the bridge binary, and Codex CLI with `app-server` and `--remote` support
- For ACP: an authenticated ACP agent executable; no Go bridge is needed

The current implementation is tested with Codex CLI 0.144.5. App-server and its WebSocket transport are experimental Codex interfaces.

## Gemini and other ACP agents

Install and authenticate Gemini CLI, then select the ACP backend:

```lua
require("seal").setup({ backend = "acp" })
```

This runs `gemini --acp --model gemini-3.8-flash --approval-mode default`. It is tested with Gemini CLI `0.62.0-preview.0`, which includes Flash 3.8 support. The [Gemini release notes](https://geminicli.com/docs/changelogs/preview/) and [ACP mode documentation](https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/acp-mode.md) describe the CLI requirements. Authenticate by running `gemini` interactively before using Seal, or use your existing configured credentials.

To choose another model or ACP executable, replace the command array. Arguments are passed directly without a shell:

```lua
require("seal").setup({
  backend = "acp",
  acp = {
    name = "Gemini",
    command = { "gemini", "--acp", "--model", "gemini-3.8-flash", "--approval-mode", "default" },
    -- mode = "autoEdit", -- optional Gemini session mode; auto-approves file edits
    -- auth_method = "gemini-api-key", -- optional; must be advertised by the agent
    -- env = { GEMINI_API_KEY = vim.env.GEMINI_API_KEY },
  },
})
```

ACP uses the same per-project queue, editor context, inline declaration previews, and patch review UI. `:SealChat` shows messages received during the current connection. `:SealNew` starts another session. Restarting the agent starts fresh sessions; loading previous ACP sessions and `:SealAttach` are not supported. Changing the backend or ACP configuration in `setup()` stops the old connection and clears its session IDs.

To let Gemini read and edit project files without approval dialogs, set `acp.mode = "autoEdit"`. Seal selects this mode through ACP before sending any prompts. Shell commands retain their normal approvals. An agent must advertise the requested mode; an unavailable or rejected mode stops session startup. Gemini requires the project folder to be trusted before enabling Auto Edit. Background orientation always uses its separate read-only policy and default session mode.

ACP has no standard per-turn sandbox setting. Declaration prompts instruct the agent not to change files, and Seal declines every permission request during those turns. This is not an operating-system read-only sandbox: an agent's tools or configured policies can execute without asking Seal. Configure the agent's own sandbox and approval policy as needed. Codex's `main_sandbox` and `main_approval_policy` options do not configure ACP agents.

File-edit permission requests with complete ACP diffs open the existing review window. Seal grants only `allow_once`, never permanent approval. It also refuses an accepted replacement if the file differs from the original text supplied by the agent, including after saving local buffer edits; reject that proposal and request a fresh edit. Tools without diffs require an explicit decision through the command approval dialog. Seal does not advertise client filesystem or terminal capabilities; agents use their own tools.

`targeted:` and `refactor:` retain their one-proposal handling: command permission requests are declined, and Seal cancels the turn after the accepted edit tool reports completion. ACP tools that write without requesting permission cannot be intercepted. A cancelled turn continues to own the queue until the agent acknowledges cancellation; an unresponsive agent is stopped after `request_timeout_ms`. Ordinary prompt duration and time spent reviewing are not limited by that timeout.

### Background repository orientation

Enable background orientation with Gemini CLI:

```lua
require("seal").setup({
  backend = "acp",
  warmup = { enabled = true },
})
```

After Neovim opens a Git repository and remains idle for 1.5 seconds, Seal starts the edit connection and a separate background Gemini process. That process reads repository instructions, the top-level structure, manifests, and key entry points. It then investigates the focused file's related definitions, callers, and tests during idle time. It uses your configured Gemini command, model, credentials, and thinking settings. Background orientation makes real model requests; it is disabled by default.

The background process has a process-specific Gemini policy that allows file reads, directory listings, globbing, and code search. Shell commands, file writes, network tools, MCP tools, and subagents are denied. All interactive permission requests are declined. This policy is passed with `--admin-policy`; it does not change your foreground agent's approvals or global Gemini settings. Background orientation currently requires a Gemini CLI executable named `gemini` with support for that flag.

Opening a Seal or Alto prompt immediately stops an active background process. Foreground requests never wait for orientation to finish. Completed findings remain available as concise, untrusted context for normal prompts and declaration previews, and the editing agent retains its normal read/search tools. Raw background conversations stay in separate per-project sessions so research cannot occupy the foreground queue.

Seal discards a project's findings when an observed source file changes on disk or in an unsaved buffer, or when the Git HEAD/ref/index changes. Changes made while Gemini is reading also invalidate its result. The current editor snapshot remains authoritative. Findings live only in the Neovim process; restarting Neovim starts fresh. An orientation failure leaves foreground editing available. Use `:SealWarmup` to explicitly retry or refresh, and `:SealWarmupStatus` to inspect progress or errors. `:SealStop` stops both agents and disables automatic warm-up until the next `setup()` or Neovim restart.

For a quiet statusline indicator, add `function() return require("seal").warmup_status() end` to a lualine section. It shows learning, ready, paused, or unavailable status; `User SealWarmupUpdated` fires when that status changes. `require("seal").status().warmup` exposes the same state as a table.

Optional limits are configured under `warmup`: `idle_ms` (1500), `resume_delay_ms` (10000 after opening a prompt), `timeout_ms` (45000 per background turn), `max_projects` (4), `max_files` (8 focused file attempts per project), `max_sources` (48 observed paths per turn), `max_file_bytes` (262144), `max_context_chars` (12000 supplied editor characters), and `max_note_chars` (4000 per result). Ordinary edits do not have these background limits. A timed-out or failed read does not retry in a loop.

## Install

With lazy.nvim:

```lua
{
  dir = vim.fn.expand("~/development/seal"),
  name = "seal.nvim",
  build = "go build -o bin/seal-bridge ./cmd/seal-bridge",
  opts = {},
}
```

Or build the bridge directly and add the repository to `runtimepath`:

```sh
cd ~/development/seal
make build
```

```lua
vim.opt.runtimepath:append(vim.fn.expand("~/development/seal"))
require("seal").setup()
```

## Use

### Send to the open Alto chat

The Alto **Seal** plugin receives prompts through a private local Unix socket. With that plugin enabled, these commands work independently of the configured Codex or ACP backend:

```vim
:SealAlto explain the code at this cursor
:'<,'>SealAlto review this selection
:SealAlto! use this additional context in the running turn
:SealAltoStatus
```

`:SealAlto` without text opens a prompt. The handoff includes the originating file, project root, language, cursor, nearby buffer contents, and selected text, including unsaved edits. It targets the focused chat in the most recently focused Alto window. The destination is captured when Alto receives the handoff; switching panes afterward does not redirect it. A pane that changes to another conversation before delivery causes an error.

Normal handoffs use Alto's existing queue when a turn is running. The `!` variant requests live steering. Alto keeps its selected model, provider, workspace, and permissions. This is a one-way handoff: responses and edit approvals remain in Alto, and Seal does not apply inline results, save the buffer, or reload files after the Alto turn.

The default socket is `~/.cache/alto/seal.sock`. Set `alto = { socket = "/another/path", timeout_ms = 20000 }` in Seal's `setup()` if the Alto plugin uses another location. The parent directory is private to your user, and the plugin closes its socket when disabled. If a handoff times out after delivery may have started, check Alto's chat and queue before retrying; Seal does not automatically resend it.

For a shortcut, map `require("seal").alto()` to a key of your choice:

```lua
vim.keymap.set("n", "<leader>aa", function() require("seal").alto() end)
```

### Agent prompts

The default mappings are:

- `<leader>ai`: open the Seal prompt
- `<leader>ac`: inspect the backing Codex conversation
- `Tab`: accept the ready declaration at the cursor marker
- `Esc`: cancel or reject the Seal job at the cursor marker

In a patch review, `Tab` accepts the complete proposed patch, `Esc` rejects it and normally lets Codex continue, `x` rejects it and stops the turn, and `q` closes the view without deciding. A rejected `targeted:` or `refactor:` patch also stops because a bounded turn gets only one proposal.

Commands provide the same operations:

```vim
:Seal explain why this test is failing
:Seal targeted: fix only the parser edge case
:Seal refactor: extract the parser's error handling
:Seal fun: load the saved state from disk
:Seal type: represent an entry in the on-disk cache
:Seal interface: define the storage API without implementations
:SealChat
:SealReview
:SealAttach
:SealAccept
:SealReject
:SealNew
:SealStop
```

`targeted:` and `refactor:` are writable main-thread convenience prefixes. `targeted:` asks for the minimum change needed, while `refactor:` asks for the smallest requested structural change and preserves behavior and public APIs unless told otherwise. Both may read and search as needed, but their prompt prohibits tests, builds, linters, formatters, other verification commands, and delegation to subagents. Each turn may propose exactly one file-change patch, which can span several files. After an accepted patch finishes applying, Seal interrupts that turn before Codex can test it or propose another patch. The expanded prompt and request remain in the persistent Codex conversation.

Recognized inline declaration prefixes are `fun`, `fn`, `function`, `type`, `class`, `method`, `struct`, `interface`, `enum`, `trait`, and `impl`. The colon is required: `fun: add build logging` requests one inline function, while `fun add build logging` is an unrestricted normal prompt. `interface:` asks for the target language's API surface and signatures without concrete implementations. Everything else is a normal Codex prompt, including unknown colon-prefixed text such as `fix: ...`.

The project root, file path, file type, cursor line and byte column, nearby buffer excerpt, and visual selection are attached as editor context. A declaration turn is also told to inspect the repository as needed, return exactly one declaration of the requested kind at that cursor, and omit helpers, surrounding declarations, prose, and Markdown. Normal agent prompts save the current modified buffer first so Codex does not edit an older on-disk version. Declaration turns are read-only and can use an unsaved buffer snapshot safely.

Normal saves run through the editor's usual `BufWritePre` hooks, including format-on-save. Seal tracks the cursor and selection through formatter edits, then captures the formatted buffer. A writable turn blocked by another modified project buffer remains queued and retries after the buffers are saved; later prompts cannot overtake it. After any main-thread turn, Seal reloads unmodified buffers changed by Codex in that project while preserving local modified buffers for manual conflict resolution.

Normal Seal turns keep Codex's `untrusted` approval policy so file changes still reach Seal's review boundary. Command-execution requests require an explicit decision by default because accepting one can let Codex retry a sandbox-blocked command with broader access even when the request has no separate escalation fields. Every Seal-owned file-change request opens the complete patch in a read-only diff window before Seal answers. `targeted:` and `refactor:` are the exception: Seal declines commands that require approval, rejects a second patch proposal, and stops the owning turn after the first accepted patch completes. If Codex unexpectedly delegates despite the bounded prompt, observed child patch requests inherit the same review and one-patch handling. A patch can cover several files; one decision authorizes or rejects that entire patch operation, though application itself can partially fail. Seal queues concurrent file-change requests and presents the decisions one at a time. Use `q` and later `:SealReview` if you want to inspect the workspace before deciding. Opening a new Seal prompt from the review defers it and targets the underlying editable source buffer. When you accept, Seal saves modified target buffers before approving the patch; Codex will apply clean hunks or report that its patch no longer applies. Once app-server reports that the accepted patch was applied, Seal immediately reloads unmodified target buffers. Edits made while the patch was applying are preserved and latched as conflicts for manual resolution. External disk changes and save/format conflicts still block acceptance.

This is an app-server approval UI, not a universal filesystem barrier. A formatter, generator, script, MCP tool, or shell command that app-server executes without requesting approval can change files directly without a patch preview. App-server can also skip a prompt after another attached client grants session-wide approval, and custom Codex or Seal permission settings can disable prompts. The bounded-prefix prompt and command declines prevent the normal verification path, but they cannot override permissions granted elsewhere. App-server does not expose a per-turn collaboration-tool switch, so the no-subagent rule is a model instruction rather than a hard security boundary. Set `auto_approve_commands = true` only if you intentionally want displayed command requests accepted without interaction; that opt-in can authorize an unsandboxed retry. Turns started from an attached Codex TUI use that TUI's permissions and are not presented as Seal-reviewed turns. Keep the workspace sandbox enabled; Seal's path checks are a review safeguard, not a replacement for it.

Before capturing context, Seal checks whether the file changed or disappeared on disk. A local/external conflict stays blocked until the buffer is reloaded, merged, or written deliberately, so a later prompt cannot accidentally overwrite either version.

One shared buffer model owns every logical declaration and prompt anchor; Neovim extmarks are display-only. Ordinary edits send only the changed line slice through that model, while reloads and whole-buffer formatters use one shared diff for every mark. You can queue locations in one or more buffers, continue editing, and accept each completed result from its marker. If a deletion or replacement makes a location ambiguous, Seal keeps the result and asks the first `Tab` to re-anchor it at the cursor; a second `Tab` accepts. If selected context changes, Seal omits that stale selection when the turn starts but keeps the job.

Ready previews retain the raw model output and recompute indentation when their anchor moves. Acceptance is transactional: a non-modifiable buffer, textlock, validation failure, or disk conflict leaves the same preview available for retry. A closed or renamed buffer still removes work that can no longer be displayed. Seal admits at most `max_pending_items` requests per project so snapshots and markers remain bounded.

Seal never opens a terminal or Zellij pane. Permission expansion and structured user-input requests are declined instead of hanging. Send another normal prompt to continue the conversation.

`SealChat` replaces the current buffer with a read-only conversation view. Press `r` to refresh and `q` to return. It shows persisted user and Codex messages from every normal, targeted, and declaration turn while omitting tool activity, editor context attachments, and system instructions.

The backing session is a normal Codex app-server thread. You can run `:SealAttach` before sending any prompt, switch to your existing Zellij terminal pane, and paste the copied command. The remote TUI creates the empty chat and Seal adopts it; a Seal prompt entered while the TUI is connecting waits for that handoff, then appears in the visible TUI conversation. Once the chat has processed a turn and has durable history, later `:SealAttach` calls copy an exact `codex resume --remote ...` command instead. Seal only copies the command; it never creates or controls the pane. A standalone TUI that was not started with the copied `--remote` endpoint cannot be adopted while it is already running.

Seal does not block model output based on language-specific AST shapes. Prefixes constrain the Codex prompt, and declarations wait for `Tab` by default. Set `auto_accept_declarations = true` to insert completed `fun:`, `type:`, and other declaration results immediately, even after switching buffers. Each automatic insertion is a separate undo step. Ambiguous insertion points, disk conflicts, and non-modifiable buffers retain a preview instead of changing the source. Set `validate_declarations = true` to opt into the stricter Tree-sitter check that requires one syntax unit of the requested kind.

## Configure

```lua
require("seal").setup({
  backend = "codex", -- or "acp" for Gemini 3.8 Flash
  codex_command = "codex",
  -- bridge = "/absolute/path/to/seal-bridge",
  startup_timeout_ms = 10000,
  request_timeout_ms = 30000,
  attach_timeout_ms = 120000,
  verbose = false,
  main_sandbox = "workspace-write",
  main_approval_policy = "untrusted",
  main_approvals_reviewer = "user",
  auto_approve_commands = false,
  auto_accept_declarations = false,
  save_before_agent = true,
  validate_declarations = false,
  max_context_chars = 120000,
  max_pending_items = 100,
  direct_reconcile_lines = 16,
  activity = {
    interval_ms = 80,
    max_summary_cells = 56,
    frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
  },
  keymaps = {
    prompt = "<leader>ai",
    chat = "<leader>ac",
  },
  prefixes = {
    fun = "function",
    type = "type",
    class = "class",
  },
  agent_prefixes = {
    targeted = "Make the minimum change needed for the request.",
    refactor = "Make only the requested behavior-preserving structural change.",
  },
  declaration_instructions = {
    interface = "Return API signatures without concrete implementations.",
  },
})
```

`declaration_instructions` is keyed by the resolved declaration kind, so aliases such as `fn` share the `function` instruction.
Custom `agent_prefixes.targeted` and `agent_prefixes.refactor` strings replace only the wording; those two prefixes remain bounded patch turns.
Set `bridge` only when the built `bin/seal-bridge` cannot be discovered through Neovim's `runtimepath`. `attach_timeout_ms` bounds how long prompts wait for a copied empty-chat TUI command to connect. A startup or request timeout retires that app-server connection because a timed-out mutating request may still complete remotely; the next prompt starts a fresh connection instead of accepting a late response into the wrong session.
Set `verbose = true` to show routine prompt-sent and turn-finished notifications. Errors, warnings, reviews, cancellations, and decisions are always shown.

The model, reasoning level, and other defaults come from the normal Codex configuration. Seal gives declaration turns a temporary read-only policy and bounded patch turns a temporary user-review policy, then restores the thread's previous sandbox and review settings for subsequent Seal or TUI turns.

Each Neovim process starts its own project thread, avoiding two editors concurrently resuming and mutating the same Codex rollout. Codex still persists the transcript in its own session storage, where the normal CLI can find it later.

## Test

```sh
make check
```

`make test-validators` additionally requires the JavaScript, Rust, and Go Tree-sitter parsers and fails instead of skipping their language-specific declaration cases.

The optional smoke test starts a real local app-server and runs two queued declaration turns through inline previews:

```sh
make smoke
```

`make protocol-smoke` verifies that sequential structured turns share one persisted conversation and that a real file stays untouched until its proposed patch is accepted.

`make acp-smoke` runs the queued declaration and reviewed-file smoke tests against Gemini 3.8 Flash through ACP. It requires an authenticated Gemini CLI and makes real model requests.
