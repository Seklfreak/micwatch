# micwatch

Tells [Home Assistant](https://www.home-assistant.io/) when you are on a call, by watching
whether the Mac's default audio input device is in use.

Two webhooks are fired on transitions:

| Transition | Webhook | Timing |
| --- | --- | --- |
| Mic becomes active | `MICWATCH_START_URL` | immediately |
| Mic becomes idle | `MICWATCH_END_URL` | after 10s of continuous idle |

Built for a **corporate-managed Mac**: no sudo, no admin rights, no Homebrew, nothing
outside your home directory — and **no privacy prompts of any kind**.

## Why no permissions are needed

micwatch reads CoreAudio's `kAudioDevicePropertyDeviceIsRunningSomewhere`, which reports
whether *any* process is running I/O on a device. That is device *state*, not audio, so it
needs neither Microphone nor Accessibility access. micwatch never opens the mic.

Start-at-login is a `launchd` user agent in `~/Library/LaunchAgents`, so there is no Login
Item to approve and no admin authentication either.

## Requirements

- macOS 12 or newer (Apple Silicon or Intel)
- Xcode or the Xcode Command Line Tools, to build the binary once
- A Home Assistant instance reachable from the Mac

> Installing the Command Line Tools needs admin rights. If you don't have them and they
> aren't already present, micwatch can't be built on that machine — nothing here works
> around that.

## Install

```bash
git clone https://github.com/Seklfreak/micwatch.git
cd micwatch
./install.sh
```

The installer asks for your two webhook URLs, writes them to `~/.config/micwatch/config`
(mode 600), compiles the binary into `~/Applications/MicWatch`, then loads and starts the
launch agent. Non-interactively:

```bash
./install.sh \
  --start-url http://homeassistant.local:8123/api/webhook/call-start-xxxxxxxx \
  --end-url   http://homeassistant.local:8123/api/webhook/call-end-yyyyyyyy
```

Confirm it came up:

```bash
tail -f ~/Library/Logs/micwatch.log
```

```
[2026-08-18 09:39:18] micwatch starting (pid 89272)
[2026-08-18 09:39:18] watching input device: USB Audio [id 111]
[2026-08-18 09:39:18] --> POST call-end
[2026-08-18 09:39:18]     call-end delivered (HTTP 200)
```

Then start a call (or record a voice memo) and watch a full cycle:

```
[2026-08-18 09:42:14] mic ACTIVE — device in-use changed
[2026-08-18 09:42:14] --> POST call-start
[2026-08-18 09:42:14]     call-start delivered (HTTP 200)
[2026-08-18 09:42:18] mic idle — device in-use changed; waiting 10s before call-end
[2026-08-18 09:42:28] mic idle for 10s
[2026-08-18 09:42:28] --> POST call-end
[2026-08-18 09:42:28]     call-end delivered (HTTP 200)
```

## The Home Assistant side

Create two webhook-triggered automations and use their webhook IDs as the URLs above.
A minimal pair:

```yaml
automation:
  - alias: Call started
    trigger:
      - trigger: webhook
        webhook_id: call-start-xxxxxxxx
        allowed_methods: [POST]
        local_only: true
    action:
      - action: input_boolean.turn_on
        target:
          entity_id: input_boolean.on_a_call

  - alias: Call ended
    trigger:
      - trigger: webhook
        webhook_id: call-end-yyyyyyyy
        allowed_methods: [POST]
        local_only: true
    action:
      - action: input_boolean.turn_off
        target:
          entity_id: input_boolean.on_a_call
```

Requests carry no body and no authentication — the webhook ID is the secret, which is why
`local_only: true` and treating the config file as sensitive both matter.

## Configuration

Settings are read from the environment first, then from the config file
(`~/.config/micwatch/config`, or wherever `MICWATCH_CONFIG` points).

| Key | Required | Default | Meaning |
| --- | --- | --- | --- |
| `MICWATCH_START_URL` | yes | — | POSTed when the mic becomes active |
| `MICWATCH_END_URL` | yes | — | POSTed when the mic has been idle long enough |
| `MICWATCH_IDLE_SECONDS` | no | `10` | Idle debounce before call-end |
| `MICWATCH_HTTP_TIMEOUT` | no | `2` | Per-request curl timeout, connect and total |
| `MICWATCH_CONFIG` | no | `~/.config/micwatch/config` | Config file path |

After editing config or source, rebuild and restart:

```bash
./install.sh                                              # safe to re-run
launchctl kickstart -k gui/$UID/io.github.seklfreak.micwatch   # config-only change
```

## Commands

```bash
micwatch --once           # print the current device and in-use state, then exit
micwatch --check          # print resolved config, webhook IDs masked
micwatch --fire start     # fire a webhook by hand (start|end)
micwatch                  # run in the foreground; Ctrl-C exits cleanly
```

`--once` needs no configuration, so it works as a bare mic probe.

## Behaviour

- **`call-start` is immediate**, `call-end` waits for `MICWATCH_IDLE_SECONDS` of continuous
  idle. Swapping headsets mid-call briefly drops the in-use flag; the debounce absorbs
  that, and the pending `call-end` is cancelled if the mic comes back.
- **The same event never fires twice in a row.** State is tracked, not just edges.
- **One `call-end` at startup**, so Home Assistant resyncs after a reboot or a missed
  end-of-call. If a call is already running at startup, `call-start` follows immediately.
- **Device switches are followed.** A listener on `kAudioHardwarePropertyDefaultInputDevice`
  re-registers the in-use listener onto whatever becomes the new default input.
- **Wake from sleep re-checks state**, since a transition can happen while asleep.
- **Failures are silent by design.** Off the home network the POST just fails: 2s timeout,
  no retries, one log line. Nothing is queued and nothing is retried later.
- **Event-driven, not polled.** CoreAudio property listeners mean no timer loop and no
  detection lag.
- **`SIGTERM` sends a final `call-end`** if a call was in progress, so logging out mid-call
  doesn't leave Home Assistant stuck.

## Troubleshooting

**Nothing in the log, agent not running.** Check it is loaded:

```bash
launchctl print gui/$UID/io.github.seklfreak.micwatch | grep -E '^\s+(state|pid|last exit) '
```

**Log repeats `missing MICWATCH_START_URL` every 10 seconds.** The config file is missing or
unreadable, and `KeepAlive` keeps restarting the daemon. Fix the config, then
`launchctl kickstart -k gui/$UID/io.github.seklfreak.micwatch`. Verify with `micwatch --check`.

**`not delivered (curl 28, HTTP 000)`.** Home Assistant was unreachable — normal when you're
not on the home network. `curl 7` is connection refused; check HA is up and the URL is right.

**`not delivered (curl 0, HTTP 404)`.** The webhook ID doesn't exist in Home Assistant. IDs are
consumed exactly as written, so re-check for typos.

**Events fire when you're not on a call.** Expected: the signal is *any* microphone use, so
dictation, Siri, and screen recordings all count. That is inherent to mic-based detection.

**macOS "Local Network" privacy.** On macOS 15 and later, a process reaching a LAN address may
need Local Network access. Delivery from the launch agent works out of the box in testing; if
POSTs fail only when launchd starts it but succeed when you run it by hand, check
**System Settings → Privacy & Security → Local Network**. That toggle is user-grantable — no
admin needed.

## Uninstall

```bash
./uninstall.sh            # removes the agent and binary, keeps config and log
./uninstall.sh --purge    # removes config and log too
```

## Implementation notes

`micwatch.swift` is a single file, deliberately.

Webhooks go out through `/usr/bin/curl` rather than `URLSession`. App Transport Security
blocks plain HTTP to a LAN address from a binary with no `Info.plist`, and `curl` isn't
subject to ATS. It also makes "fail fast and stay quiet" trivial. The cost is a short-lived
fork per event, a handful of times an hour.

All state lives on one serial dispatch queue, which every CoreAudio listener callback and
the debounce timer are dispatched to, so no locking is needed. POSTs go out on a second
serial queue, which keeps their ordering intact (the startup `call-end` can be immediately
followed by a `call-start`).

### Approaches that don't work

Worth recording, since they look plausible:

- **AppleScript / JXA + AVFoundation.** `AVCaptureDevice.isInUseByAnotherApplication` would
  be ideal, but the ObjC bridge doesn't expose `AVCaptureDevice` — `ObjC.import('AVFoundation')`
  and an explicit `NSBundle` load both leave it `undefined` on macOS 26.
- **`ioreg` and `IOAudioEngineState`.** The old shell one-liner relies on `AppleHDA`, which
  Apple Silicon doesn't use. No such keys exist in the registry there.
- **Hammerspoon**, which wraps this same CoreAudio property in `hs.audiodevice:inUse()`, is a
  fine choice if you already run it. micwatch exists to avoid a ~50 MB scriptable automation
  app and its Accessibility grant for a single boolean.
