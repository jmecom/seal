# Seal

Seal is a small Neovim interface for a real Codex session.

Press one key, enter a prompt, and Seal routes it in one of two ways:

- A normal prompt goes unchanged to a persistent Codex thread. Seal opens a Codex TUI on the right, attached to the same live app-server thread, so approvals and follow-up conversation use the normal terminal interface.
- `fun:`, `type:`, `class:`, and other declaration prefixes create a temporary read-only fork of that thread. The fork sees the existing chat and repository, returns one declaration, and Seal previews it inline. Press `Tab` to insert it or `Esc` to discard it.

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

- `<leader>ss`: open the Seal prompt
- `<leader>st`: open or focus the shared Codex terminal
- `Tab`: accept a declaration while its preview is visible
- `Esc`: reject a declaration while its preview is visible

Commands provide the same operations:

```vim
:Seal explain why this test is failing
:Seal fun: load the saved state from disk
:Seal type: represent an entry in the on-disk cache
:SealTerminal
:SealAccept
:SealReject
:SealNew
:SealStop
```

Recognized declaration prefixes are `fun`, `fn`, `function`, `type`, `class`, `method`, `struct`, `interface`, `enum`, `trait`, and `impl`. Everything else is a normal Codex prompt, including unknown colon-prefixed text such as `fix: ...`.

The current buffer, cursor, file type, and visual selection are attached as editor context. Normal agent prompts save the current modified buffer first so Codex does not edit an older on-disk version. Declaration forks are read-only and can use an unsaved buffer snapshot safely.

Before showing a declaration, Seal parses the proposed full buffer with Tree-sitter and verifies that the inserted range contains one syntax unit of the requested kind. A parser for the current file type must be installed. Set `validate_declarations = false` only if you prefer manual preview review for an unsupported language.

## Configure

```lua
require("seal").setup({
  codex_command = "codex",
  save_before_agent = true,
  validate_declarations = true,
  terminal_width = 0.42,
  keymaps = {
    prompt = "<leader>ss",
    terminal = "<leader>st",
  },
  prefixes = {
    fun = "function",
    type = "type",
    class = "class",
  },
})
```

The model and reasoning level come from the Codex thread. Change them normally from the terminal TUI; declaration forks inherit them.

Each Neovim process starts its own project thread, avoiding two editors concurrently resuming and mutating the same Codex rollout. Codex still persists the transcript in its own session storage, where the normal CLI can find it later.

## Test

```sh
make check
```

The optional smoke test starts a real local app-server and runs the complete declaration flow through an inline preview:

```sh
make smoke
```

`make protocol-smoke` runs a lower-level app-server resume/fork contract check.
