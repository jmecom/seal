# Seal

Seal is a small Neovim interface for a real Codex session.

Press one key, enter a prompt, and Seal routes it in one of three ways:

- A normal prompt goes unchanged to one persistent Codex thread. Seal immediately leaves a spinner and prompt summary at the originating cursor until the turn finishes. When app-server requests approval for a native Codex patch, Seal opens a multi-file diff before answering. `:SealChat` shows the persisted conversation in a read-only Markdown buffer.
- `targeted:` and `refactor:` use that same thread as bounded patch turns. Codex may inspect the repository, then proposes one reviewed patch and stops after app-server applies it. These turns do not run tests, builds, linters, or formatters.
- `fun:`, `type:`, `class:`, and other declaration prefixes use read-only turns in the same conversation. Each cursor gets an inline spinner and prompt summary while Codex works, then an inline declaration preview.

You can mark several prompts immediately. On each project thread, Seal keeps every request visible and runs the model turns in submission order, one at a time, so every request and result becomes context for the next one. Only the request that owns the current turn animates; queued markers are static. Collocated requests share one marker with a count and remain independently addressable, newest first.

Codex owns the agent loop, tools, conversation history, and compaction. Seal keeps only one thread ID per project root in the current Neovim process.

## Requirements

- Neovim 0.11 or newer
- A Tree-sitter parser only if declaration validation is explicitly enabled
- Go 1.23 or newer for the small bridge binary
- Codex CLI with `app-server` and `--remote` support

The current implementation is tested with Codex CLI 0.144.5. App-server and its WebSocket transport are experimental Codex interfaces.

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

Normal Seal turns keep Codex's `untrusted` approval policy so file changes still reach Seal's review boundary. Seal auto-approves command-execution requests by default, while every Seal-owned file-change request opens the complete patch in a read-only diff window before Seal answers. `targeted:` and `refactor:` are the exception: Seal declines commands that require approval, rejects a second patch proposal, and stops the owning turn after the first accepted patch completes. If Codex unexpectedly delegates despite the bounded prompt, observed child patch requests inherit the same review and one-patch handling. A patch can cover several files; one decision authorizes or rejects that entire patch operation, though application itself is not atomic and can partially fail. Seal queues concurrent file-change requests and presents the decisions one at a time. Use `q` and later `:SealReview` if you want to inspect the workspace before deciding. Opening a new Seal prompt from the review defers it and targets the underlying editable source buffer. When you accept, Seal saves modified target buffers before approving the patch; Codex will apply clean hunks or report that its patch no longer applies. External disk changes and save/format conflicts still block acceptance.

This is an app-server approval UI, not a universal filesystem barrier. A formatter, generator, script, MCP tool, or shell command that app-server executes without requesting approval can change files directly without a patch preview. App-server can also skip a prompt after another attached client grants session-wide approval, and custom Codex or Seal permission settings can disable prompts. The bounded-prefix prompt and command declines prevent the normal verification path, but they cannot override permissions granted elsewhere. App-server does not expose a per-turn collaboration-tool switch, so the no-subagent rule is a model instruction rather than a hard security boundary. Set `auto_approve_commands = false` to restore per-command dialogs for normal turns. Turns started from an attached Codex TUI use that TUI's permissions and are not presented as Seal-reviewed turns. Keep the workspace sandbox enabled; Seal's path checks are a review safeguard, not a replacement for it.

Before capturing context, Seal checks whether the file changed or disappeared on disk. A local/external conflict stays blocked until the buffer is reloaded, merged, or written deliberately, so a later prompt cannot accidentally overwrite either version.

One shared buffer model owns every logical declaration and prompt anchor; Neovim extmarks are display-only. Ordinary edits send only the changed line slice through that model, while reloads and whole-buffer formatters use one shared diff for every mark. You can queue locations in one or more buffers, continue editing, and accept each completed result from its marker. If a deletion or replacement makes a location ambiguous, Seal keeps the result and asks the first `Tab` to re-anchor it at the cursor; a second `Tab` accepts. If selected context changes, Seal omits that stale selection when the turn starts but keeps the job.

Ready previews retain the raw model output and recompute indentation when their anchor moves. Acceptance is transactional: a non-modifiable buffer, textlock, validation failure, or disk conflict leaves the same preview available for retry. A closed or renamed buffer still removes work that can no longer be displayed. Seal admits at most `max_pending_items` requests per project so snapshots and markers remain bounded.

Seal never opens a terminal or Zellij pane. Permission expansion and structured user-input requests are declined instead of hanging. Send another normal prompt to continue the conversation.

`SealChat` replaces the current buffer with a read-only conversation view. Press `r` to refresh and `q` to return. It shows persisted user and Codex messages from every normal, targeted, and declaration turn while omitting tool activity, editor context attachments, and system instructions.

The backing session is a normal Codex app-server thread. To use the full Codex TUI for that exact conversation, run `:SealAttach`, switch to your existing Zellij terminal pane, and paste the copied command. Seal only copies the `codex resume --remote ...` command; it never creates or controls the pane.

Seal does not block model output based on language-specific AST shapes. Prefixes constrain the Codex prompt, and the inline preview plus `Tab` is the approval boundary. Set `validate_declarations = true` to opt into the stricter Tree-sitter check that requires one syntax unit of the requested kind.

## Configure

```lua
require("seal").setup({
  codex_command = "codex",
  main_sandbox = "workspace-write",
  main_approval_policy = "untrusted",
  main_approvals_reviewer = "user",
  auto_approve_commands = true,
  save_before_agent = true,
  validate_declarations = false,
  max_pending_items = 100,
  activity = {
    interval_ms = 80,
    max_summary_cells = 56,
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

The model, reasoning level, and other defaults come from the normal Codex configuration. Seal gives declaration turns a temporary read-only policy and bounded patch turns a temporary user-review policy, then restores the thread's previous sandbox and review settings for subsequent Seal or TUI turns.

Each Neovim process starts its own project thread, avoiding two editors concurrently resuming and mutating the same Codex rollout. Codex still persists the transcript in its own session storage, where the normal CLI can find it later.

## Test

```sh
make check
```

The optional smoke test starts a real local app-server and runs two queued declaration turns through inline previews:

```sh
make smoke
```

`make protocol-smoke` verifies that sequential structured turns share one persisted conversation and that a real file stays untouched until its proposed patch is accepted.
