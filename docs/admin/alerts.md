# Alerts

The [admin UI](README.md) can tell you when something happens on your server, by email, to chat services, or to any webhook. This page covers what it alerts on, how to set up each way, and how to check that the alerts arrive.

## What it alerts on

- **Health**: a component goes down or comes back, a new release is out, a database schema changes, a certificate of a public URL is about to expire. See [Monitoring](monitoring.md).
- **The admin UI itself**: someone signs in, or fails to, or changes something there (kind `admin`).
- **Backups**: one fails, or the last good one gets older than 36 hours, and when they work again. See [Backups](../backups.md).
- **Thresholds**, once when they start and once when they end: max users or max accounts near or at the limit ([Near and full](../limits.md#near-and-full)); Sync data changing without metrics from the Sync server; a spike of Sync errors; a database growing fast; alerts failing; the [setup migrations](monitoring.md#setup-migrations) of a database server not in order. See [Needs attention](monitoring.md#needs-attention).
- **Sign-ups**: a refused sign-up, and with self-hosted accounts a new account, a new device, a burst of sign-ups (see [Maintenance and retention](storage.md#maintenance-and-retention)).
- **Security**, with self-hosted accounts: an account blocked by the rate limits and, with the security history on, a changed password, primary email, or way to sign in or recover the account (kind `security`). See [Security history](accounts.md#security-history).

Alerts are collected and sent at most every 10 minutes, as one message:

- At most 20 alerts of each kind go in one message, the rest are counted. Sign-ins and changes in the admin UI are one kind, `admin`.
- The emails of refused sign-ups are shortened and stripped of line breaks. Those that do not look like an email are recorded as "invalid email".

The alerts go by email (`ADMIN_ALERT_EMAIL`), to the destinations of `ADMIN_NOTIFY`, or both: each gets every alert. Their times follow the admin UI's [time zone](README.md#time-zone). The settings are in [Settings](../reference/settings.md#notifications).

## Do you need an SMTP server?

- **For the alerts, no.** Set `ADMIN_NOTIFY` instead of, or besides, `ADMIN_ALERT_EMAIL`. Without self-hosted accounts and with `ADMIN_NOTIFY` set, nothing complains about the missing SMTP server.
- **With self-hosted accounts, yes.** People cannot sign up or sign in without one, see [Requirements](../accounts.md#requirements). `ADMIN_NOTIFY` replaces email for the admin UI's alerts only.
- **Invitations and the notices to account owners** are emails: they go to people, not to admins, and need the SMTP server.

## By email

1. Fill in the SMTP server of `FXA_SMTP_*` in `.env`, even without self-hosted accounts. `FXA_SMTP_HOST` left at its placeholder (`<REPLACE_WITH_YOUR_SMTP_SERVER>`) counts as unset.
1. Set the address the alerts go to:

   ```ini
   ADMIN_ALERT_EMAIL=alice@example.com
   ```

1. Start the stack again, then send a test email (below).

The password is sent over TLS only: STARTTLS, or `FXA_SMTP_SECURE=true` on port 465.

What the admin UI does with it:

- **The Email (SMTP) row** of the Health table. Every hour, with `FXA_SMTP_HOST` set, the admin UI connects to the SMTP server, starts TLS and signs in, then leaves without sending anything. A wrong password or a server that does not answer turns the row down, with an event and an alert.
- While it is down it tries again every 10 minutes, not every minute: some servers block an address after a few wrong passwords.
- **An email that could not be sent** is kept and goes out with the next one, up to 200 lines. Alerts that could not be sent wait, at most 20 of each kind (the newest), and the rest are counted by kind.
- **The overview** says when the last alert email went out, or why the last one failed and how many alerts are waiting. That is kept in memory: after a restart it says "none sent since the start".
- **Send a test email**, under the Health table, sends one email to `ADMIN_ALERT_EMAIL`. Without it, it goes to the admin signed in with single sign-on, never to an address typed in a form. The page shows the SMTP server's answer when it fails, and the test is in the event log.

## Destinations

`ADMIN_NOTIFY` is a list of destinations: one URL each, separated by commas, in single quotes in `.env`:

```ini
ADMIN_NOTIFY='ntfy://ntfy.sh/my-secret-topic,slack://hooks.slack.com/services/T000/B000/XXXX'
```

| Install | How to set it |
|---|---|
| docker compose | edit `.env`, then `docker compose up -d` |
| Quadlets | at install, `prepare_environment.sh` asks for them, separated by commas or spaces, and turns a pasted `https://` webhook URL of Slack or Discord into `slack://` or `discord://`. Later: `ADMIN_NOTIFY=` in `firefox-sync-admin.container`, see [Change a setting](../install/podman.md#change-a-setting) |
| Helm | `admin.notify`, a list of these URLs, then `helm upgrade` |

The scheme says the kind. For the services that give you a webhook URL, it is that URL with `https://` replaced by the scheme:

| Destination | URL |
|---|---|
| [Slack](https://docs.slack.dev/messaging/sending-messages-using-incoming-webhooks/) | `slack://hooks.slack.com/services/T…/B…/…`. [Mattermost](https://docs.mattermost.com/developers/integrate/webhooks/incoming)'s incoming webhooks take the same: `slack://mattermost.example.com/hooks/<key>` |
| [Discord](https://support.discord.com/hc/en-us/articles/228383668-Intro-to-Webhooks) | `discord://discord.com/api/webhooks/<id>/<token>` |
| [Microsoft Teams](https://support.microsoft.com/en-us/workflows/send-messages-in-teams-using-incoming-webhooks) | `teams://<the workflow URL without https://>`, from the workflow template "Send webhook alerts to a channel". The old Office 365 connectors are being retired |
| [ntfy](https://docs.ntfy.sh/publish/) | `ntfy://ntfy.sh/<topic>`, `ntfy://<access token>@ntfy.example.com/<topic>` or `ntfy://user:password@…`. On ntfy.sh, pick a topic name nobody guesses |
| [Gotify](https://gotify.net/docs/pushmsg) | `gotify://gotify.example.com/<application token>`, also under a path: `gotify://example.com/gotify/<token>` |
| [Telegram](https://core.telegram.org/bots/tutorial) | `telegram://<bot token>/<chat id>`. The chat is your own id after you sent the bot a message, a group's (`-100…`, with the bot in it), or `@channelname` (with the bot an admin of the channel) |
| [Matrix](https://spec.matrix.org/latest/client-server-api/) | `matrix://<access token>@matrix.example.org/<room>`, with a user for the bot and the room it joined: its id (`!abc:example.org`) or alias (`#alerts:example.org`) |
| any other | `webhook://example.com/path`; a header with `?@Name=value`; Basic auth with `user:password@`. For n8n, Home Assistant (`webhook://ha.example.com/api/webhook/<id>`), Node-RED, and the incoming webhooks of Rocket.Chat and Mattermost (they show `text`). See [Webhook schema](#webhook-schema) |

### Writing the URLs

- **Without HTTPS**: add `+http` after the scheme (`ntfy+http://`, `gotify+http://`, `matrix+http://`, `webhook+http://`...) for a server on your network, e.g. `webhook+http://homeassistant.lan:8123/api/webhook/<id>`.
- **Special characters**: a comma in a URL is written `%2C`. A `/`, `?` or `#` in a user or password is percent-encoded (`%2F`, `%3F`, `%23`), otherwise the rest would read as the host. The admin UI refuses an `@` after the host, other than the `?@Name=` headers.
- **Tokens over plain HTTP**: with `+http` and a token (a header, Basic auth, the path of a Slack, Discord or Teams webhook) to a host outside your network, the admin UI warns at the start and on the Configuration page. Anybody on the way can read the token. Inside your network means loopback, a private address, one label, `.lan`, `.local`, `.internal` or `.home.arpa`.

An `ADMIN_NOTIFY` the admin UI cannot use stops it at the start. The error names the destination by its number and its `scheme://host` only:

```text
ADMIN_NOTIFY, destination 2 of 2 (telegram://…): no chat id: telegram://<bot token>/<chat id>, …
```

**The URLs hold tokens**: anybody with one can post to your channel. `ADMIN_NOTIFY` is a secret of `.env`, like the passwords. The admin UI never shows or logs more than `scheme://host` (`slack://hooks.slack.com`, `telegram://api.telegram.org`), and leaves out the ntfy topic, which on ntfy.sh is the password. That holds on the Configuration page, the overview, Prometheus, its logs and the errors of the destinations, whose answers are scrubbed of the URL's secret parts.

### What each one gets

Each message has a title (`firefox-sync: <the alert>`, or `firefox-sync: N events`), one line per alert with its time, the counts of those left out, and the time zone. It ends with a link to the Activity page when the admin UI's public address is known, from `ADMIN_OIDC_REDIRECT_URL`.

| Destination | Format |
|---|---|
| Slack, Discord | light markup, the title in bold |
| Teams | an Adaptive Card: text without markdown, a button to the admin UI |
| Matrix | a notice with its HTML |
| ntfy, Gotify | plain text, with a higher priority when an alert needs a look (a component down, backups, thresholds, security changes, blocks, sign-up bursts) |
| Telegram | plain text |
| webhook | JSON, see [Webhook schema](#webhook-schema) |

The messages stay within each service's limit: Discord 2000 characters, Telegram 4096, Slack 40,000, Teams' 28 KB card, ntfy 4 KB. The lines that do not fit are counted: "... and N more lines in the admin UI, Activity".

What comes from outside, such as the email of a refused sign-up, can neither mention anybody, nor become a link, nor format anything:

- Every `@`, every `://` and the dots of host names get a word joiner (U+2060, invisible). No service turns `@channel`, `@here`, `@room` or `https://phish.example/x@y` into a ping or a link. Text copied from a message carries those invisible characters.
- Slack gets `<`, `>` and `&` escaped. Discord gets markdown escaped and mentions off (`allowed_mentions`). Matrix gets the HTML escaped and `m.mentions` empty. Telegram and Teams get no markup at all.
- The webhook's `text` is defanged too; its `events[].text` is the text as it is.

### Whether they arrive

- **Retries**: each attempt has 10 seconds. One that gets no answer or a 5xx is tried once more 2 seconds later. A refusal (4xx: a wrong token, a deleted webhook) is not.
- **Queues**: what could not be sent waits for the next round, like the emails (at most 20 of each kind, the newest; the rest counted). Each destination has its own queue: one that fails does not hold back the others or the email.
- **Timing**: the destinations of a round are sent at the same time, and the next round waits for the slowest: at most about 22 seconds.
- **Lost alerts**: a destination that refuses the message as it is (400, 413, 422) would refuse it again. Those alerts are dropped, logged and counted, not sent again every round.
- **The Notifications row** of the Health table lists each destination with when it last got an alert. It is down, with the destination's answer, while the last alert to one failed: an event, an alert, and a line in [Needs attention](monitoring.md#needs-attention). Nothing is sent for the row itself.
- **The overview**, under Alerts, says the same per destination, and how many alerts wait.
- **Send a test notification**, under the Health table, sends one message to every destination right away, and shows the result of each. The test is in the event log. It is kept apart from the alerts: it does not change the Notifications row or the failure counter.

The Prometheus metrics of the alerts, per destination, are in [Prometheus](monitoring.md#prometheus). Their `destination` label is the `scheme://host`; a second one of the same host gets ` (2)`.

## Webhook schema

The generic webhook gets a `POST` with `Content-Type: application/json` and `User-Agent: firefox-sync-admin/<version>`:

```json
{
  "source": "firefox-sync",
  "kind": "health",
  "severity": "warning",
  "title": "firefox-sync: health: Sync server is down: connection refused",
  "text": "firefox-sync: health: Sync server is down: connection refused\n\n2026-10-17 10:00  health: Sync server is down: connection refused\n\nTimes in Europe/Rome. Details: https://admin.example.com/activity",
  "link": "https://admin.example.com/activity",
  "events": [{"time": "2026-10-17T08:00:00Z", "kind": "health", "text": "Sync server is down: connection refused"}],
  "dropped": {}
}
```

| Field | Value |
|---|---|
| `kind` | the kind of every event: `sign-up refused`, `health`, `update`, `sign-in`, `admin`, `blocked`, `sign-up burst`, `backup`, `attention` or `security`. `several` when they differ, `test` for the test notification |
| `severity` | `warning` when one of them needs a look (the same kinds as ntfy's higher priority), `info` otherwise |
| `title` | the title of the message |
| `text` | all of it as plain text, at most 16,000 characters |
| `link` | the Activity page, or `""` when the admin UI's public address is not known |
| `events` | the alerts, with the time in UTC |
| `dropped` | those left out by the cap of 20 per kind, by kind |
