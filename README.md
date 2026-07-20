# Seal

Seal is a small Neovim interface for a real Codex session.

Press one key, enter a prompt, and Seal routes it in one of three ways:

- A normal prompt goes unchanged to one persistent Codex thread. Seal immediately leaves a spinner and prompt summary at the originating cursor until the turn finishes. When app-server requests approval for a native Codex patch, Seal opens a multi-file diff before answering. `:SealChat` shows the persisted conversation in a read-only Markdown buffer.
- `targeted:` and `refactor:` use that same thread with tighter instructions. `targeted:` asks for the smallest change that satisfies the request; `refactor:` asks for the smallest requested structural change while preserving behavior and public APIs.
- `fun:`, `type:`, `class:`, and other declaration prefixes use read-only turns in the same conversation. Each cursor gets an inline spinner and prompt summary while Codex works, then an inline declaration preview.

You can mark several prompts immediately. On each project thread, Seal keeps every spinner visible and runs the model turns in submission order, one at a time, so every request and result becomes context for the next one.

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
- `Tab`: accept the ready declaration on the cursor line
- `Esc`: cancel or reject the Seal job on the cursor line

In a patch review, `Tab` accepts the complete proposed patch, `Esc` rejects it and lets Codex continue, `x` rejects it and stops the turn, and `q` closes the view without deciding.

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

`targeted:` and `refactor:` are writable main-thread convenience prefixes. Seal replaces `targeted:` with general minimal-change guidance. It replaces `refactor:` with guidance to make only the requested structural change, preserve existing behavior and public APIs unless explicitly requested otherwise, and avoid adjacent cleanup. The expanded prompt and request appear in the persistent Codex conversation.

Recognized inline declaration prefixes are `fun`, `fn`, `function`, `type`, `class`, `method`, `struct`, `interface`, `enum`, `trait`, and `impl`. The colon is required: `fun: add build logging` requests one inline function, while `fun add build logging` is an unrestricted normal prompt. `interface:` asks for the target language's API surface and signatures without concrete implementations. Everything else is a normal Codex prompt, including unknown colon-prefixed text such as `fix: ...`.

The project root, file path, file type, cursor line and byte column, nearby buffer excerpt, and visual selection are attached as editor context. A declaration turn is also told to inspect the repository as needed, return exactly one declaration of the requested kind at that cursor, and omit helpers, surrounding declarations, prose, and Markdown. Normal agent prompts save the current modified buffer first so Codex does not edit an older on-disk version. Declaration turns are read-only and can use an unsaved buffer snapshot safely.

Normal saves run through the editor's usual `BufWritePre` hooks, including format-on-save. Seal tracks the cursor and selection through formatter edits, then captures the formatted buffer. It refuses to start a writable turn while another project buffer has unsaved changes. After any main-thread turn, it reloads unmodified buffers changed by Codex in that project while preserving local modified buffers for manual conflict resolution.

Normal Seal turns keep Codex's `untrusted` approval policy so file changes still reach Seal's review boundary. Seal auto-approves command-execution requests by default, while every Seal-owned file-change request opens the complete patch in a read-only diff window before Seal answers. A patch can cover several files; one decision authorizes or rejects that entire patch operation, though application itself is not atomic and can partially fail. Seal queues concurrent file-change requests and presents the decisions one at a time. Use `q` and later `:SealReview` if you want to inspect the workspace before deciding. Opening a new Seal prompt from the review defers it and targets the underlying editable source buffer. When you accept, Seal saves modified target buffers before approving the patch; Codex will apply clean hunks or report that its patch no longer applies. External disk changes and save/format conflicts still block acceptance.

This is an app-server approval UI, not a universal filesystem barrier. An auto-approved formatter, generator, script, MCP tool, or shell command can change files directly without a patch preview. App-server can also skip a prompt after another attached client grants session-wide approval, and custom Codex or Seal permission settings can disable prompts. Set `auto_approve_commands = false` to restore per-command dialogs. Turns started from an attached Codex TUI use that TUI's permissions and are not presented as Seal-reviewed turns. Keep the workspace sandbox enabled; Seal's path checks are a review safeguard, not a replacement for it.

Before capturing context, Seal checks whether the file changed or disappeared on disk. A local/external conflict stays blocked until the buffer is reloaded, merged, or written deliberately, so a later prompt cannot accidentally overwrite either version.

Declaration jobs are anchored with Neovim extmarks. You can queue them before or during a normal, `targeted:`, or `refactor:` turn, prompt several locations in one or more buffers, continue editing, and accept each completed result from its marker. Local inserts, deletes, undo, formatting, and accepted Codex patches re-anchor each job. If an edit changes text explicitly selected for a queued request, Seal omits that stale selection when the turn starts but keeps the job. A closed buffer, renamed file, or conflicting on-disk change still blocks the result. Accepted declarations format normally on the next save.

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

The model, reasoning level, and other defaults come from the normal Codex configuration. Seal makes declaration turns read-only, then restores the thread's previous sandbox and review settings for subsequent turns.

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
