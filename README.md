# wall-e

**A small coding robot, written in Perl.**

wall-e is a Linux-first, CLI-only coding agent. Give it a task and it can read
files, make changes, run commands, and work through the results using any
model server that speaks the OpenAI-style Responses API: a local llama.cpp
server or a hosted provider.

Named for **Larry Wall** and **WALL-E**: a little robot that gets to work.

## Why wall-e?

A coding agent does not need a large software stack to be useful. wall-e starts
with one Perl executable, four tools, and a direct connection to your model
provider. No Node.js, npm, OpenAI SDK, or agent framework.

The goal is a small dependency tree and source you can actually read. Fewer
moving parts mean fewer things to install, update, audit, and trust.

## Requirements

- Linux with Perl **5.20+** and `/bin/sh`.
- An endpoint and model supporting Responses API function tools, plus an API
  key if your provider requires one.
- The Perl modules below, including their dependencies.

| Module | Minimum version | Purpose |
| --- | --- | --- |
| `HTTP::Tiny` | 0.080 | HTTP requests; part of Perl core, although older installations may need an update |
| `IO::Socket::SSL` | 2.056 | HTTPS support |

All other modules used by the executable are Perl core modules.

Prefer packages from your distribution's repositories:

| Distribution | Command |
| --- | --- |
| Debian, Ubuntu | `sudo apt install perl libio-socket-ssl-perl` |
| Fedora, RHEL | `sudo dnf install perl perl-IO-Socket-SSL` |
| Arch | `sudo pacman -S perl perl-io-socket-ssl` |
| Alpine | `sudo apk add perl perl-io-socket-ssl` |

On Fedora and RHEL, install the full `perl` package, not just
`perl-interpreter`, so the core modules are present. `HTTP::Tiny` 0.080 ships
with Perl 5.36 and later; on older Perl, update it from CPAN. CPAN installation
of everything is also supported:

```sh
cpanm --installdeps .
```

## Quick start

From the source directory, after installing the dependencies:

```sh
export WALLE_BASE_URL='https://api.openai.com/v1'   # or your own server
export WALLE_MODEL='your-api-model-id'
export WALLE_API_KEY='your-api-key'                 # omit if not required

./wall-e --help
./wall-e 'Explain this repository'
```

There is no default endpoint: wall-e only connects where you tell it to. Use
the exact model ID your server or account offers. Results depend on the
model's tool-calling ability; local models need a server and chat template
that return function calls (for llama.cpp, typically `--jinja`).

To put the executable on your PATH:

```sh
mkdir -p "$HOME/.local/bin"
install -m 755 wall-e "$HOME/.local/bin/wall-e"
```

To uninstall, delete that file.

Then work from your project directory:

```sh
cd /path/to/project

# Complete one task and exit.
wall-e 'Find the failing test and fix it'

# Choose a model and reasoning effort explicitly.
wall-e --model MODEL_ID --reasoning medium 'Review the last commit'

# Allow shell commands and file changes without approval prompts.
wall-e --yes 'Run the tests and fix the failure'

# Read a task from stdin.
printf '%s\n' 'Explain this repository' | wall-e
```

When a task argument is supplied, it is used as the prompt. Stdin is read
as the task only when no task argument is supplied and stdin is not a terminal.
A piped task leaves no terminal for approvals, so that run is read-only unless
`--yes` is set.

## Terminal behavior

Model text goes to stdout. Tool activity, approval prompts, and errors go to
stderr.

When stdout is a terminal, wall-e formats the model's Markdown with basic ANSI
styling: bold and headings, colored code, bullets, aligned tables, and code
blocks without their fences. This is a small built-in formatter, not a full
Markdown renderer. Piped or redirected output stays raw Markdown, so scripts
and tools like `glow` see the original text. Set `NO_COLOR` (or use
`TERM=dumb`) to get raw Markdown in the terminal too.

## Tools

| Tool | Behavior |
| --- | --- |
| `read` | Read up to 64 KiB of UTF-8 text |
| `write` | Create or overwrite a UTF-8 file; parent directory must exist |
| `edit` | Replace exactly one occurrence of text; reject missing or ambiguous matches; files up to 1 MiB |
| `shell` | Run `/bin/sh -c`; capture combined stdout/stderr, exit status, and signal |

Read calls run automatically. Shell calls and file changes require `y` or `yes`
unless `--yes` is set. Tool failures and denials are returned to the model.

Approval prompts show what will happen: the command for `shell`, the path and
numbered content for `write` (noting whether it overwrites an existing file),
and removed (`-`) and added (`+`) lines for `edit`. Control characters and
Unicode direction overrides are shown as `\x{..}` escapes, so text cannot hide
in a prompt. Content longer than 40 lines is cut off with a `… N more lines`
note, and the prompt offers `v=show all N lines`: answer `v` to print the full
content, then answer `y` or `n`. Any answer other than `y`, `yes` or `v` denies
the action.

Without a terminal to ask on, and without `--yes`, the run is read-only: the
model is offered only the `read` tool and told it cannot run commands or change
files, and wall-e notes this on stderr. Any other tool call it makes anyway is
refused.

Each shell call starts in wall-e's working directory with fresh shell state.
Use `cd subdir && ...` within a command when needed. Commands receive no
interactive stdin.

## Configuration

| Option | Environment / default |
| --- | --- |
| `--base-url URL` | `WALLE_BASE_URL`; required, no default |
| `--model MODEL` | `WALLE_MODEL`; required |
| `--reasoning EFFORT` | Omitted by default; passed through to the selected model |
| `--yes`, `-y` | Approve shell calls and file changes automatically |
| `--timeout N` | Shell timeout in seconds; default `60` |
| `--max-steps N` | API calls per user turn; default `30` |
| `--help`, `-h` | Show usage and exit |

Set an API key, if your provider needs one, through `WALLE_API_KEY`; without it
no `Authorization` header is sent. wall-e deliberately ignores `OPENAI_API_KEY`
and other provider variables, so a key exported for other tools is never sent
to a server you point wall-e at. It does not save the key to a configuration
file, and removes `WALLE_API_KEY` from the environment of shell commands. Shell
commands otherwise inherit the process environment, including any other
secrets in it.

Endpoints must support `/responses` and use `https://` or `http://`. Plain
HTTP works, for example for a local model on your LAN, but for any host other
than `localhost` or `127.0.0.1` wall-e prints a warning on each start: prompts,
file contents, command output and any API key travel unencrypted. Use it only
on a network you trust. TLS certificate verification is enabled
and HTTP redirects are disabled. HTTP requests have a 180-second timeout and
are not automatically retried.

## Instructions and context

The built-in developer prompt is short and can be inspected in the executable.
It describes the working directory, asks the model to inspect before editing,
follow project instructions, and report what it actually verified.

Root `AGENTS.md`, when present, is appended to those instructions. The model is
asked to read applicable nested `AGENTS.md` files; nested discovery is not
programmatically enforced. Instruction files are read as text, not executed as
extensions.

Each run starts with no history; nothing is saved between runs. Within a run,
API requests use `store: false` and replay response items, including encrypted
reasoning and linked tool results. This flag is not a guarantee about a
provider's broader retention policies. If a run fails partway, any actions
already performed remain in effect.

One-shot runs exit `0` on success and `1` on errors (API failure, step limit,
bad options). They exit `2` if any shell call or file change was denied,
because the task did not run as asked. A read-only run (no terminal, no
`--yes`) that only reads exits `0`; pass `--yes` when a script expects changes.

## Execution boundaries

wall-e runs with your user's permissions. File tools can access paths outside
the working directory. An approved shell command has the same access as a
command you run yourself. Approval prompts are not a sandbox or a defense
against every form of prompt injection.

Choose your own container, VM, user account, or other isolation if you need it.
The harness does not attempt to decide which development tasks are acceptable.

Prompts, instructions, file contents, and command output included in the
conversation are sent to your configured provider. Choose an endpoint you
trust.

Shell output returned to the model is capped at 64 KiB. Commands stop when the
timeout or observed 1 MiB capture limit is reached. Process-group cleanup does
not contain deliberately detached processes, and these limits are not OS
resource quotas.

