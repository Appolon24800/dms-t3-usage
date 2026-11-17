# T3 Code Usage for DankMaterialShell

A DankBar widget that shows how much of your AI subscriptions you have left
(Claude, Codex, Grok, ...), using the numbers [T3 Code](https://github.com/pingdotgg/t3code)
already tracks on its **Usage → Limits** page. No API keys, no provider logins:
if T3 Code can see your limits, so can the bar.

- **Pill**: `Claude 94%`, the share left of the tightest limit (or the session
  or weekly one), colored green, orange, then red as it runs out. With several
  providers it rotates between them.
- **Popout**: every provider and window with a bar, what is left, and when it
  resets (`Resets in 4h 38m · 23:19`). Providers with several accounts (a
  CLIProxyAPI hub) are pooled like on T3's Limits page, with one chip per account.
- **Back to T3 Code**: right-click the pill, or use the button in the popout,
  to bring T3 Code to the front (focuses its window on niri, launches it otherwise).

## Requirements

- DankMaterialShell (or a fork using the same plugin API), any compositor
- T3 Code desktop app or `t3 serve`, running on this machine, and its `t3`
  command (the desktop app sets it up in `~/.local/bin/t3`; check with `t3 --version`)
- `python3` (standard library only)

## Install

```sh
git clone https://github.com/Appolon24800/dms-t3-usage \
  ~/.config/DankMaterialShell/plugins/t3Usage
```

Then in DMS: **Settings → Plugins → T3 Code Usage → enable**, and add the
**T3 Code Usage** widget to a bar section.

## How it reads T3 Code

`scripts/t3_usage.py` runs every minute (configurable):

1. Finds the local server in `~/.t3/userdata/server-runtime.json` (loopback
   only, and only if the pid there really is T3 Code).
2. Asks the `t3` CLI for a **read-only** session
   (`t3 auth session issue --scope orchestration:read --ttl 12h`). The token is
   cached `0600` in `$XDG_RUNTIME_DIR/dms-t3-usage/` and reissued shortly
   before it expires; the session it replaces is revoked. It shows up in T3 Code
   under Sharing & access as `dms-t3-usage`.
3. Opens T3's `subscribeServerConfig` stream over its WebSocket RPC, reads the
   first snapshot, and closes. It keeps each provider's `usageLimits` windows
   and plan name, plus the accounts of every CLIProxyAPI hub T3 polls. Only the
   first letter of a hub account's email is kept, as its badge.

Providers whose accounts have no limits to report (API keys, custom
endpoints) are left out.

### Codex (or anything) through a CLIProxyAPI hub

When Codex talks to a hub instead of ChatGPT directly, T3 only knows its limits
if the hub is added under **Settings → Providers → Usage providers → Add hub**
(hub URL and management key). That setting is per environment: add it on the
machine this widget runs on, or the widget only sees the local providers.

## Troubleshooting

**"T3 Code was updated in the background. Restart T3 Code..."** - T3 updated
itself on disk while the old version is still running. The new `t3` CLI then
refuses to touch the running server's database, so no new token can be issued.
Restart T3 Code; the widget picks up again on its next refresh.

**"T3 Code isn't running"** - start it; the server must be up for its numbers.

Run the script by hand to see what the widget sees:

```sh
python3 ~/.config/DankMaterialShell/plugins/t3Usage/scripts/t3_usage.py
```

## Settings

| Setting | Default | |
| --- | --- | --- |
| Pill shows | Tightest limit | or Session (5h) / Weekly |
| Provider name in pill | on | `Claude 94%` vs `94%` |
| Pill rotation | 10 s | 0 pins one provider |
| Pinned provider | first | name or id, used when rotation is 0 |
| Refresh interval | 60 s | minimum 15 |
| Open command | built in | e.g. `gtk-launch t3code` |

## License

MIT. Unofficial; not affiliated with T3 Tools or DankMaterialShell.
