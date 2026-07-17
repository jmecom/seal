# Seal

Seal is a small Neovim interface for a real Codex session.

Press one key, enter a prompt, and Seal routes it in one of two ways:

- A normal prompt goes unchanged to a persistent Codex thread and runs in the background. `:SealChat` shows the persisted conversation in a read-only Markdown buffer.
- `fun:`, `type:`, `class:`, and other declaration prefixes create independent temporary read-only forks of that thread. Each fork inherits the conversation and can inspect the repository. Each cursor gets an inline spinner and prompt summary while Codex works, then an inline declaration preview. Several marked locations can run concurrently.

Codex owns the agent loop, tools, conversation history, and compaction. Seal keeps only one thread ID per project root in the current Neovim process.

## Requirements

- Neovim 0.11 or newer
- A Tree-sitter parser for languages where declaration prefixes are used
- Go 1.23 or newer for the small bridge binary
- Codex CLI with `app-server`, `--remote`, and `thread/fork` support

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

Commands provide the same operations:

```vim
:Seal explain why this test is failing
:Seal fun: load the saved state from disk
:Seal type: represent an entry in the on-disk cache
:SealChat
:SealAttach
:SealAccept
:SealReject
:SealNew
:SealStop
```

Recognized declaration prefixes are `fun`, `fn`, `function`, `type`, `class`, `method`, `struct`, `interface`, `enum`, `trait`, and `impl`. Everything else is a normal Codex prompt, including unknown colon-prefixed text such as `fix: ...`.

The current buffer, cursor, file type, and visual selection are attached as editor context. Normal agent prompts save the current modified buffer first so Codex does not edit an older on-disk version. Declaration forks are read-only and can use an unsaved buffer snapshot safely.

Normal saves run through the editor's usual `BufWritePre` hooks, including format-on-save. Seal tracks the cursor and selection through formatter edits, then captures the formatted buffer. It refuses to start a writable turn while another project buffer has unsaved changes. After any main-thread turn, it reloads unmodified buffers changed by Codex in that project while preserving local modified buffers for manual conflict resolution.

Before capturing context, Seal checks whether the file changed or disappeared on disk. A local/external conflict stays blocked until the buffer is reloaded, merged, or written deliberately, so a later prompt cannot accidentally overwrite either version.

Declaration jobs are anchored to their cursor lines. You can prompt several locations in one or more buffers, let the forks finish in any order, and accept each result from its marker. Accepting one result rebases non-overlapping jobs in the same buffer. Ordinary edits, completion/formatting edits, file changes, and workspace-writing main-thread turns cancel affected jobs rather than applying stale output. Accepted declarations format normally on the next save.

Seal never opens a terminal or Zellij pane. Normal turns can edit the workspace but use a non-interactive approval policy: sandbox escalation and user-input requests are declined instead of hanging. Send another normal prompt to continue the conversation.

`SealChat` replaces the current buffer with a read-only conversation view. Press `r` to refresh and `q` to return. It shows persisted user and Codex messages from the main thread while omitting tool activity, editor context attachments, and system instructions. Temporary declaration forks intentionally do not appear in this conversation.

The backing session is a normal Codex app-server thread. To use the full Codex TUI for that exact conversation, run `:SealAttach`, switch to your existing Zellij terminal pane, and paste the copied command. Seal only copies the `codex resume --remote ...` command; it never creates or controls the pane.

Before showing a declaration, Seal parses the proposed full buffer with Tree-sitter and verifies that the inserted range contains one syntax unit of the requested kind. A parser for the current file type must be installed. Set `validate_declarations = false` only if you prefer manual preview review for an unsupported language.

## Configure

```lua
require("seal").setup({
  codex_command = "codex",
  main_sandbox = "workspace-write",
  main_approval_policy = "never",
  save_before_agent = true,
  validate_declarations = true,
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
})
```

The model, reasoning level, sandbox, and other defaults come from the normal Codex configuration. Declaration forks inherit the main thread's model settings.

Each Neovim process starts its own project thread, avoiding two editors concurrently resuming and mutating the same Codex rollout. Codex still persists the transcript in its own session storage, where the normal CLI can find it later.

## Test

```sh
make check
```

The optional smoke test starts a real local app-server and runs two declaration flows in parallel through inline previews:

```sh
make smoke
```

`make protocol-smoke` runs a lower-level app-server resume/fork contract check.
