# Plan: G1 Claude Terminal — Core Implementation

## Context

The Even Realities G1 glasses app currently calls the DeepSeek API when the user long-presses the left TouchBar. The goal is to replace this with a Claude-powered wearable terminal that routes all queries through a local Claude Code CLI relay on the user's desktop. This gives the glasses real agentic capabilities (web search, file access, bash, session memory) managed by Claude Code itself. A direct Anthropic API fallback is used when the relay is unreachable, with an `[OFFLINE]` indicator on the glasses display.

**Key constraints established in research/design:**
- Claude.ai Projects/Cowork have no public API — web UI only
- The Claude Agent SDK is Python/TypeScript only — cannot embed in Flutter
- `claude -p --resume <session_id>` is the programmatic interface that handles its own session memory
- One unified mode (no mode switching) — Claude decides which tools to use per query

---

## Architecture

```
G1 Glasses
  ↕  dual BLE
Flutter App (phone)
  └─ PRIMARY  ──► relay (localhost:9090 or public URL) ──► claude -p --resume <sid>
  └─ FALLBACK ──► api.anthropic.com/v1/messages  (relay offline → [OFFLINE] tag)
```

The relay server runs on the user's desktop, in the CWD of their project. Claude Code CLI handles session memory via `~/.claude/` session files — the relay only passes session IDs through.

---

## Files to Create / Modify

| File | Action | Purpose |
|------|--------|---------|
| `lib/services/cowork_relay_service.dart` | **CREATE** | HTTP client for the desktop relay |
| `lib/services/api_claude_service.dart` | **CREATE** | Fallback direct Anthropic API client |
| `lib/models/claude_session.dart` | **CREATE** | Holds relay session ID + offline flag |
| `lib/services/evenai.dart` | **MODIFY** | Replace DeepSeek, add wake word, dispatch to relay/fallback |
| `lib/ble_manager.dart` | **MODIFY** | Triple-tap → reset session (instead of mode cycle) |
| `lib/views/settings_page.dart` | **CREATE** | API key, relay URL, secret token, wake phrases config |
| `tools/relay/server.js` | **CREATE** | Node.js relay: spawns `claude -p` subprocess |
| `pubspec.yaml` | **MODIFY** | Add `shared_preferences: ^2.3.0` |

---

## Step-by-Step Implementation

### 1. `lib/models/claude_session.dart` (new)

```dart
class ClaudeSession {
  String? relaySessionId;   // returned by relay, passed back on --resume
  bool isOffline = false;   // true when relay unreachable, triggers [OFFLINE] tag
  final List<Map<String, String>> messages; // fallback API history [{role, content}]

  ClaudeSession() : messages = [];
  void addUser(String text)      => messages.add({'role':'user',    'content':text});
  void addAssistant(String text) => messages.add({'role':'assistant','content':text});
  void reset() { relaySessionId = null; messages.clear(); isOffline = false; }
  static const int maxTurns = 20;
}
```

---

### 2. `lib/services/cowork_relay_service.dart` (new)

POST to relay server. Throws `RelayOfflineException` on timeout/connection refused.

```
POST <relayUrl>/query
Headers: Authorization: Bearer <secret>   (if secret configured)
Body:    { "message": "...", "session_id": "abc123" | null }
Response: { "response": "...", "session_id": "abc123" }
```

- Reads relay URL and secret token from `shared_preferences`
- If secret is non-empty, adds `Authorization: Bearer <secret>` header
- 15-second timeout; throws `RelayOfflineException` on any network failure
- On 401: throws `RelayAuthException` (show "Relay auth failed — check secret token" on glasses)
- On success: updates `session.relaySessionId` from response
- Uses `dio` (already a dependency)

---

### 3. `lib/services/api_claude_service.dart` (new)

Direct call to `api.anthropic.com/v1/messages` — used only when relay is offline.

- API key: `const String.fromEnvironment('ANTHROPIC_API_KEY')` with fallback to `shared_preferences`
- Model: `claude-sonnet-4-6`, `max_tokens`: 1024
- Passes full `session.messages` list for multi-turn context (capped at `ClaudeSession.maxTurns`)
- System prompt: `"You are a helpful assistant on Even Realities G1 smart glasses. The display shows 5 lines at a time. Be concise. No markdown."`
- Returns `content[0].text`; on HTTP error returns human-readable string

---

### 4. `tools/relay/server.js` (new)

Minimal Node.js HTTP server (stdlib only, no framework).

```js
// POST /query { message, session_id }
// → spawns: claude -p --output-format json [--resume <session_id>]
//           with message passed via stdin
// → parses JSON output for result + session_id
// → responds: { response, session_id }
```

Key implementation details:
- Use `child_process.spawn` (not `exec`) — avoids shell injection, handles long output
- Pass message via **stdin** (not CLI arg) to avoid shell escaping issues:
  `spawn('claude', ['-p', '--output-format', 'json', '--resume', sid], { stdin: message })`
- Parse `--output-format json` response: `{ result, session_id, ... }`
- Working directory: `process.env.RELAY_CWD` or `process.cwd()` — so Claude has file access to the user's project
- Port: `process.env.PORT || 9090`
- Logs startup errors if `claude` is not in PATH

**Auth (required for internet exposure):**
- Read `RELAY_SECRET` from env var
- If set, reject requests without `Authorization: Bearer <RELAY_SECRET>` with HTTP 401
- If not set, accept all requests (localhost-only use)

**Internet exposure options (documented in `tools/relay/README.md`):**

| Option | Setup | Pros | Cons |
|--------|-------|------|------|
| ngrok | `ngrok http 9090` | Free, instant | URL changes on restart (free tier) |
| Cloudflare Tunnel | `cloudflared tunnel` | Free, stable hostname | More setup |
| Tailscale | Install + `100.x.x.x:9090` | Stable hostname, no open port | Requires Tailscale on phone too |
| VPS | Deploy to Fly.io / Railway | Always on | Requires server + Claude Code on VPS |

Recommended for most users: **Cloudflare Tunnel** (free, stable subdomain that doesn't change on restart).

`tools/relay/package.json`: minimal, no dependencies.

---

### 5. `lib/services/evenai.dart` (modify)

**a) Add session state and wake word config (class fields):**
```dart
final ClaudeSession _session = ClaudeSession();

// read from shared_preferences at startup
List<String> _wakePhrases = ['hey claude', 'ok claude', 'claude'];
bool _requireWakeWord = true;
```

**b) Wake word detection — add private helpers:**
```dart
bool _hasWakeWord(String text) =>
    _wakePhrases.any((w) => text.toLowerCase().contains(w));

String _stripWakeWord(String text) {
  final lower = text.toLowerCase();
  for (final w in _wakePhrases) {
    if (lower.contains(w)) {
      final idx = lower.indexOf(w);
      return text.substring(idx + w.length).trim();
    }
  }
  return text;
}
```

**c) Replace DeepSeek API call in `recordOverByOS()` (~line 149):**
```dart
// Wake word gate
if (_requireWakeWord && !_hasWakeWord(combinedText)) {
  startSendReply('Say "Hey Claude" to start');
  isEvenAISyncing.value = false;
  return;
}
final query = _stripWakeWord(combinedText);

// Dispatch
String answer;
try {
  answer = await CoworkRelayService().query(query, _session);
  _session.isOffline = false;
} on RelayAuthException {
  // Don't fall back — auth failure is a config error, not a connectivity issue
  startSendReply('Relay auth failed. Check secret token in settings.');
  isEvenAISyncing.value = false;
  return;
} on RelayOfflineException {
  _session.isOffline = true;
  answer = await ApiClaudeService().sendChatRequest(query, _session);
}

_session.addUser(query);
_session.addAssistant(answer);

// Store in history UI (existing)
saveQuestionItem(query, answer);
updateDynamicText('$query\n\n$answer');
isEvenAISyncing.value = false;
startSendReply(answer);
```

**d) Offline indicator in `startSendReply()`:**
```dart
// Prepend status tag before measureStringList
final tag = _session.isOffline ? '[OFFLINE] ' : '';
final displayText = tag + text;
// pass displayText (not text) to EvenAIDataMethod.measureStringList()
```

**e) Reset session in `clear()`:**
```dart
_session.reset();  // add this line
```

**f) Add `resetSession()` public method (for triple-tap):**
```dart
void resetSession() {
  _session.reset();
  startSendReply('Session reset');
}
```

---

### 6. `lib/ble_manager.dart` (modify)

Triple-tap events (cases 4 & 5) currently fall through to the `default` print. Update:

```dart
case 4: // triple-tap left — reset Claude session
  EvenAI.get.resetSession();
  break;
case 5: // triple-tap right — reset Claude session (either side works)
  EvenAI.get.resetSession();
  break;
```

---

### 7. `lib/views/settings_page.dart` (new)

Simple `StatefulWidget` reachable from `FeaturesPage`. All values persisted via `shared_preferences`.

| Field | Type | Default |
|-------|------|---------|
| Anthropic API key | Password text field | env var |
| Relay URL | Text field | `http://localhost:9090` |
| Relay secret token | Password text field | _(empty = no auth)_ |
| Require wake word | Switch | `true` |
| Wake phrases | Text field (comma-separated) | `hey claude, ok claude, claude` |

On save: update `shared_preferences` + reload values in `EvenAI` instance.

**Relay URL can be any HTTP/HTTPS URL** — localhost for home use, or a public tunnel URL (ngrok, Cloudflare Tunnel) when away from the desktop.

---

### 8. `pubspec.yaml` (modify)

```yaml
dependencies:
  shared_preferences: ^2.3.0   # add this line
```

---

## Wake Word Approach

STT prefix/contains match against `combinedText` (set by native speech layer).
- No on-device keyword spotting plugin needed — simpler, no native code
- Fires after TouchBar release (full transcript available)
- Acceptable for the glasses UX since the user is already holding the TouchBar while speaking
- Default: `['hey claude', 'ok claude', 'claude']`
- Strip the matched phrase before sending to relay

---

## Session Memory

Memory is fully owned by Claude Code on the desktop:
- First query: relay calls `claude -p --output-format json` → gets back `session_id`
- Subsequent queries: relay calls `claude -p --output-format json --resume <session_id>`
- Session files live in `~/.claude/` on the desktop
- Flutter app only stores the opaque `session_id` string
- Triple-tap resets `session_id` to null → next query starts a fresh Claude Code session

---

## Verification

1. **Relay server**: `curl -X POST localhost:9090/query -d '{"message":"what is 2+2"}' -H 'Content-Type: application/json'` → returns `{ response: "4", session_id: "..." }`
2. **Session continuity**: send two queries to relay with same `session_id` → second response references context from first
3. **Wake word**: unit test `_hasWakeWord("hey claude what time is it")` == true; `_stripWakeWord("hey claude what time is it")` == `"what time is it"`
4. **Offline fallback**: point relay URL at a dead port, trigger query → response has `[OFFLINE]` prefix, came from direct API
5. **Auth failure**: set wrong secret token, trigger query → glasses show "Relay auth failed" and no fallback occurs
6. **Session reset**: triple-tap left → glasses show "Session reset"; next query starts fresh (no `--resume` in relay call)
7. **E2E on device**: connect G1, long-press, say "Hey Claude, what files are in this directory", relay running in project root → glasses display files list with no `[OFFLINE]` tag
8. **Web search E2E**: say "Hey Claude, what is today's weather in London" → Claude Code uses WebSearch tool, glasses show current weather
