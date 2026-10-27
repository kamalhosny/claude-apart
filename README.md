# claude-apart

Run several Claude Code accounts on one computer at the same time, and keep
them apart. For example: a private account and a work account.

- You always see which account a window belongs to.
- Nothing from one account reaches another account unless you allowed that
  direction.
- Reading can be allowed one way. For example, your private account may look
  at work files when you ask.

The core rule:

> Whatever a Claude session reads becomes part of that account's
> conversation, and that conversation goes to the cloud. So content from
> profile A may enter a session of profile B only if B was granted read
> access to A. Nothing is ever pushed from one profile into another.

Local files are not visible to an employer. Reading them into a work session
is the leak. Every rule below protects that line.

Written in bash and core Perl. No other dependencies. macOS is the tested
platform; Linux is best effort.

## Install

From a clone:

```sh
git clone https://github.com/OWNER/claude-apart.git
cd claude-apart
./install.sh
```

Or in one line:

```sh
curl -fsSL https://raw.githubusercontent.com/OWNER/claude-apart/main/install.sh | sh
```

- It installs into `~/.local/share/claude-apart` (set `CLAUDE_APART_HOME` to
  use another folder). No root needed.
- It adds one line to `~/.zshrc` and `~/.bashrc` (only the ones that exist)
  that puts `<prefix>/bin` first on your `PATH` (if neither exists, it creates
  `~/.zshrc`). The line ends with
  `# claude-apart`.
- It never touches `~/.local/bin`, and never changes the real `claude`.
- Run it again to update. Your launchers stay. If you already have a config,
  it also runs `claude-apart sync`.
- It refuses to run inside a Claude session.

Open a new terminal after installing.

## Quick start

```sh
claude-apart setup        # guided: finds ~/.claude, adds profiles, logs in, installs the guard
claude                    # the default profile (or the one bound to your Herdr workspace)
claude-work               # always the work profile
claude-personal           # always the personal profile
claude-apart new work project   # Herdr: a new workspace bound to a profile
```

Other commands:

| Command | What it does |
|---|---|
| `claude-apart add <name>` / `remove <name>` | Manage profiles. `remove` keeps the profile folder unless you ask. |
| `claude-apart login <name>` | Log in a profile and record which account it is. |
| `claude-apart status` | Each profile: folder, expected and actual account, grants, guard installed. |
| `claude-apart sync` | Install the guard into every profile again. |
| `claude-apart check` | Self-test of the guard and the account checks. |
| `claude-apart copy <from> <to>` | Careful copy of safe items between profiles. |
| `claude-apart uninstall` | Remove everything the tool added. |

Example profiles in this document: `work` (🟧 WORK) and `personal` (🟪 PERS).

## How the guard works

Each profile gets its own config folder (`CLAUDE_CONFIG_DIR`). Four layers
are installed into every profile by `setup` and `sync`:

1. **Permission deny rules** in the profile's `settings.json`: no reading of
   other profiles' folders (unless granted), and no writing to any of them.
2. **A PreToolUse hook** that checks every tool call. It blocks a call that
   names a foreign path in any spelling (`~/...`, `$HOME/...`, absolute,
   relative from the working folder, `file://`), that writes to a foreign
   path, that starts another profile's launcher, or that reads from or types
   into another profile's Herdr pane. A grep that would reach a foreign
   folder from a parent folder is blocked too.
3. **Launcher refusal**: inside a Claude session, `claude` and `claude-<name>`
   refuse to start a profile other than the session's own.
4. **Account checks**: the launcher and a prompt hook compare the logged-in
   account with the one recorded for the profile. A mismatch refuses to start
   or blocks the prompt. The status line shows a red `WRONG ACCOUNT` badge.

The guard fails closed: if a hook breaks, the call is blocked. A block
message never contains another profile's email or content.

Every session also shows a status line badge (`[WORK]` on the profile colour
plus the email). If you already had a status line command, it is kept and the
badge goes in front of it.

Which profile plain `claude` starts:

1. A `claude-<name>` launcher always wins.
2. Inside a Claude session: the session's own profile. Never the default.
3. Else the profile bound to the Herdr workspace.
4. Else the default profile.

## Threat model and known limits

The guard targets **accidents by a model**, not a determined adversary. It
stops things like: "check my notes" sent to the work account, a grep that
reaches too far, a prompt that names another profile's folder, a Claude that
starts another profile's launcher. It does **not** stop a model that is
actively trying to get around it. A real wall needs a separate OS user (or
the sandbox below). Protected is **content**: memory, chats, files, screen
output. That other profiles exist, and their names and folder paths, is not
treated as secret.

What the tool does not cover:

**Shared places outside a profile**
- Claude Code's MCP-log cache (`~/Library/Caches/claude-cli-nodejs` on macOS,
  `${XDG_CACHE_HOME:-~/.cache}/claude-cli-nodejs` on Linux) is shared by all
  profiles. claude-apart treats it as owned by the profile in `~/.claude`,
  so other profiles cannot read it. Their own MCP logs still land there.
- The old shared temp root `/tmp/claude-<uid>` is treated the same way. Each
  profile gets its own temp folder through `CLAUDE_CODE_TMPDIR`
  (`${XDG_STATE_HOME:-~/.local/state}/claude-apart/tmp/<name>`, mode 700). If
  a future Claude Code stops honouring that variable, temp files go back to
  the shared root.
- Content you copied into shared folders yourself, and editing shared code
  repos (allowed on purpose, because that is normal coding).
- MCP servers with their own disk access, other terminal multiplexers (tmux
  `capture-pane`), the clipboard and screenshots.

**Shell forms the guard cannot follow**
- Obfuscated paths or commands, and symlinks that point into foreign folders
  from elsewhere.
- `${VAR%...}`-style parameter operators, and `$VAR` values the hook cannot
  see (it uses its own environment, not the Bash tool's).
- Relative paths after `env -C`, `git -C`, `make -C`, `tar -C`.
- Symlinks or folders made earlier in the same command (`ln -s ... && cd ...`).
- `cd $(echo ~)`, quoted `eval`, `shopt -s cdable_vars`, `os.chdir('..')` in
  `python -c`.
- `cat */x` where the glob crosses a symlink in the current folder.
- Programs that glob quoted text themselves (perl `glob()`, ruby `Dir.glob`).
- `env -i` with commands other than claude (`env -i` plus claude is blocked).
- A very large heredoc can use most of the 5 second hook budget. Past the
  budget the guard blocks.

**Herdr forms the guard cannot follow**
- herdr calls built from stdin: `... | xargs herdr`, `parallel herdr :::`.
- `ssh <host> herdr ...` (another machine's Herdr).
- Runner commands under a renamed name (a copy or alias of `env`, `xargs`).
- Text typed into a pane that hides the launcher: an option value before
  `claude-<name>`, a launcher in a quoted variable, cleared env with claude
  on a later line or through stdin.

**False blocks you may hit**
- Quoted text or heredocs that only mention `herdr pane read`,
  `claude-<other>` or `CLAUDE_CONFIG_DIR` are blocked, mostly in commit
  messages. Work-around: `git commit -F <file>`.
- Agent, TodoWrite and MCP tool inputs that name a path inside the installed
  tool folder are blocked (it is write-protected for every profile).
- Inside Herdr, if the workspace label cannot be read, plain `claude` refuses
  and asks you to start `claude-<name>`. A label with no profile prefix still
  means the default profile.

**Developing claude-apart itself**
- Every profile's sessions are denied writes to the installed copy. If you
  run claude-apart straight from a clone, that clone becomes read-only to
  your sessions. Develop in a separate clone and install from it.

**Out of scope**
- Anything you type in a terminal yourself. The guard only checks Claude
  Code tool calls and prompts.
- Another OS user, root, or a process outside Claude Code.

### Optional: Claude Code's sandbox

For a stronger wall you can turn on Claude Code's own OS-level sandbox and
deny reads of the other profiles' folders. Per its
[sandboxing docs](https://code.claude.com/docs/en/sandboxing), the settings
are `sandbox.enabled` and `sandbox.filesystem.denyRead` / `allowRead`. In a
profile's `settings.json`, for example:

```json
{
  "sandbox": {
    "enabled": true,
    "filesystem": { "denyRead": ["~/.claude-work"] }
  }
}
```

Things to know:

- It is off by default and claude-apart does not set it for you. Check the
  docs page for the current setting names and path rules.
- `denyRead` applies to sandboxed Bash commands only. The built-in Read tool
  is covered by claude-apart's deny rules.
- A sandbox can break normal work: docker, ssh and gh often need files or
  sockets outside the allowed set. Allow what you need with `allowRead` and
  test your usual commands.

## Herdr

If you use Herdr, claude-apart marks workspaces:

- A workspace label starts with `<emoji> <TAG> · `, for example
  `🟪 PERS · ideas`. That prefix is the binding: plain `claude` in that
  workspace opens that profile.
- `claude-apart new personal ideas` creates such a workspace.
- When a session starts inside Herdr, a hook adds the prefix to the workspace
  and tab labels if it is missing. It never doubles it, and it only warns if
  the workspace already carries another profile's prefix.
- The guard blocks reading output from a pane of a profile you may not read,
  and typing into any other profile's pane. Listing stays allowed.

## Uninstall

```sh
claude-apart uninstall            # guard, PATH lines, launchers, installed copy
claude-apart uninstall --purge    # also asks to delete the config and temp folders
```

- It removes only what claude-apart added to each profile's `settings.json`
  (your own settings come back as they were), the marked PATH lines (a
  symlinked `.zshrc` stays a symlink), the launchers and the installed copy.
- It never deletes profile folders or logins.
- It stops without removing the installed copy if a profile's settings
  cannot be cleaned, because hooks that point to a missing copy would block
  everything.
- It refuses to run inside a Claude session.

## How it differs from other tools

Several tools switch Claude Code accounts. Short and neutral:

- **claude-acc**: switches between accounts.
- **claude-profile**: switches between accounts.
- **claude-swap**: switches between accounts.
- **ccs**: switches between accounts.

What claude-apart adds is a guard between profiles: separation is the default,
sessions are kept out of each other's files, panes and launchers, and a wrong
logged-in account is refused. Check each tool's own README for what it does.

## Tests

```sh
bash tests/run.sh
```

## License

MIT. See [LICENSE](LICENSE).
