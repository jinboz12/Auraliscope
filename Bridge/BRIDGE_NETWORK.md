# Auraliscope Bridge over the local network (iPad phase, 2.1 dev)

How an Auraliscope Bridge plugin instance on a Mac sends its **analysis results** directly to an Auraliscope display on
another device of the local network (Auraliscope for iPad), without the Mac app. The messages are those of
[PROTOCOL.md](PROTOCOL.md) (protocol 3, analysis schema 1), byte for byte; this document adds the carrier, discovery,
pairing and the security model. No audio ever crosses the network.

```
DAW ─ Bridge VST3/AU ─ analysis thread ─ mailbox ─ sender thread ─ NetLink (TLS-PSK, own queue) ══ Wi-Fi/Ethernet ══ iPad receiver ─ display session ─ panels
          │ audio thread: copy into a ring, nothing else (unchanged)
```

## Discovery

The display advertises DNS-SD service type `_auraliscope._tcp` (the type `BridgeDiscovery.h` reserved), instance name =
the device's name, on the port of its TLS listener, with TXT keys (all written from the real constants, never typed):

| Key | Value |
|---|---|
| `proto` | `3` (`ABR_PROTOCOL_VERSION`) |
| `schema` | `1` (`ABR_ANALYSIS_SCHEMA`) |
| `platform`, `app`, `ver` | `iPadOS`, `Auraliscope`, app version and build |
| `role` | `display` |
| `transport` | `tls-psk` (only these are offered as network displays; `tcp` is for unauthenticated test beacons) |
| `rid` | the receiver ID, 16 random bytes in hex, stable for the installation: what a pairing is bound to |
| `pair` | present only while pairing is open: the port of the pairing listener |

The plugin window lists displays only while the person asks it to scan (macOS asks for the DAW's Local Network permission
then). A display of another protocol or schema is listed with "needs an update" and cannot be chosen.

## Carrier

TCP with TLS 1.2 and a pre-shared key, cipher suite `TLS_PSK_WITH_AES_128_GCM_SHA256`, through Network.framework on both
ends (`Bridge/Plugin/Core/BridgeNetLink.cpp`, `iPad/App/BridgeReceiver.swift`). TCP keepalive (2 s idle, 1 s interval,
3 probes) notices a vanished peer within about 5 s; Nagle is off. The plugin connects to the service by name
(Network.framework resolves it), so a display whose address or port changed is found again.

**PSK identity**: the Mac's pairing ID (16 random bytes, 32 hex characters, `network-device-id`). **Key**: 32 random
bytes per Mac and display, created by the display at pairing. The display holds one key per paired Mac (Keychain,
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), the Mac one file per display
(`~/Library/Application Support/Auraliscope Bridge/Receivers/<rid>.pairing`, mode 0600, folder 0700). A handshake with
an unknown identity or a wrong key fails (`unknown PSK identity`, `bad record MAC`) before any Bridge byte is read.

## Pairing

1. On the iPad: *Wireless Display ▸ Pair ▸ Show a Pairing Code*. It shows 8 characters of the Crockford alphabet
   (40 bits; case, dashes and spaces ignored, O read as 0, I and L as 1) and opens a **pairing listener** for 3 minutes,
   for one Mac, closing after 5 failed handshakes. Its port is advertised as TXT `pair`.
2. In the plugin window: *Find displays*, then *Pair…* on that display, and type the code. The plugin derives the
   pairing key `PBKDF2-HMAC-SHA256(code, "AuraliscopeBridgePair1" ‖ rid, 200 000 iterations, 32 bytes)` and connects
   to the pairing port with PSK identity `pair`. A wrong code fails the handshake.
3. Over that encrypted connection the plugin sends **PAIR_REQUEST** (type 32: device ID, computer name, host, plugin
   version). The iPad asks its person: *Allow “<Mac>” to send analysis to this iPad?*
4. **PAIR_GRANT** (type 33: receiver ID, receiver name, a fresh 32-byte key) or **PAIR_DENY** (type 34: reason). The plugin
   accepts a grant only when its receiver ID is the one advertised by the display the person chose, and stores it.

Pairing is per Mac user account; every plugin instance of that user can then use the display. *Forget* on the iPad
deletes a Mac's key (its connections close and its handshakes fail from then on).

## Choosing where an insert's results go

Each instance sends to **one display at a time**: Auraliscope on this Mac over the local socket (the default, unchanged),
or one paired network display. The person chooses it in that instance's plugin window (*Send here*, *Stop*, *Use this
Mac*); nothing is ever redirected without that choice. The choice is saved with the DAW project (`receiver=<rid>` in the
plugin state, read by the same parser as `id=` and `name=`; older plugins ignore the line) and reconnects when the
project is reopened, on a Mac that is paired with that display.

**Simultaneous displays:** an instance sent to an iPad is not shown in Auraliscope on the Mac meanwhile (the Mac app
sees the instance leave, as when a plugin is removed); other instances are unaffected. Different inserts can go to
different displays. Showing one instance on the Mac and an iPad at once is **not supported**, by design for now.
Investigated for build 2: `BridgeCore` holds one carrier, one subscription and one 256 KB result mailbox per instance,
and one `StreamAnalyzer` whose options are set by the subscriber — spectrogram mode (Classic/Enhanced), spectrum
channels (L R or every channel), spatial coherence and the SPATIAL_CONFIG geometry (custom speaker layouts). Two
displays can ask for different values of each. Doing it properly needs, per receiver: its own subscription and
mailbox (bounded, dropped independently), its own pending-send budget and backpressure, and either one analysis per
distinct option set (CPU per extra analysis, outside the audio thread) or a rule for which display's options win and
an explicit notice on the other. Pause/Reset would also need a scope rule (they act on the one measurement every
display shows). That is a protocol and plugin change of its own, not a display change, so this phase keeps the
explicit one-display rule: the plugin window always says where the insert is shown, and *Use this Mac* brings it back.

## The receiving end on the iPad (build 2)

The iPad runs Build 120's own receiver, `BridgeServer.c`, without its Unix listening socket
(`abr_server_start_detached`). Each accepted TLS connection is pumped through a `socketpair`: one end is handed to the
server (`abr_server_adopt`, at most 8 pending adoptions), the other is read and written by `ConnectionPump` on the
network queue, bounded to 256 KB toward the server and 256 KB in flight toward the network. The server therefore
applies exactly the Mac's rules (framing limit, HELLO validation, WELCOME capabilities, SUBSCRIBE, stale-result
filtering, COMMAND and ACK, SPATIAL_CONFIG and the pending-send limit), and the iPad receives the spatial field like
the Mac. The peer user-ID check of the local socket does not apply to adopted sockets; the TLS pre-shared key is what
admits a peer. An adopted connection must say HELLO within 5 s (`abr_server_set_adopted_hello_deadline_ms`), or the server
closes it and the pump closes the network connection, so a paired peer that connects and stays silent cannot hold one
of the 8 slots; a TLS handshake that never completes is cancelled by the pump after 10 s. Connections on the Mac's
local socket are not timed out (Bridge/scripts/test-transport.sh checks all three).

## HELLO additions

Over the network the plugin adds two HELLO fields: tag 11 `bytes[16]` its device ID (its PSK identity) and tag 12 UTF-8 ≤
63 the computer name. Older displays skip unknown tags, so this is not a protocol version change.

## Bounds and real-time safety

| Where | Bound | When reached |
|---|---|---|
| Plugin: output buffer | 512 KB (unchanged) | nothing more is queued |
| Plugin: results in flight on the network | 64 KB (`kNetHighWater`) | no new RESULT is queued; the 256 KB mailbox keeps only the newest state |
| NetLink: bytes accepted for sending | 256 KB (`kMaxInFlight`) | `send` refuses; the bytes stay in the output buffer |
| NetLink: received bytes waiting | 64 KB (`kMaxInbound`) | it stops reading; TCP holds the peer back |
| Display: one message | 1 MiB + 16 (the framing limit) | the connection closes before the payload is read |
| Display: connections | 8; no HELLO within 5 s, or no TLS within 10 s: closed | further connections are refused |
| Display: pending sends per connection | 64 | the connection closes (a peer that reads nothing) |

The host's audio thread is untouched (`BridgeCore::process` is unchanged: a copy into the preallocated ring). Connecting,
resolving, the handshake and all I/O happen on the link's dispatch queue and the existing sender thread, which never
blocks (every NetLink call returns at once). Measured with the real VST3 in the test host: a display that stops reading
for 8 s, a dropped connection and a refused key leave the audio bit-identical and the worst `process()` call at 17–26 µs
(Bridge/scripts/test-network.sh, docs/IPAD_TEST_REPORT.md).

Reconnection: from 1 s, backing off to 5 s; a refused key is reported at once ("pair again"). A pause commanded by a
display ends when that display disconnects (the existing rule of PROTOCOL.md).

## Security model

Protected: confidentiality and integrity of every message; only paired Macs can send results to a display, and only a
display holding the key can receive them or command the instance (COMMAND carries the instance's session ID, as on the
local socket). A pairing needs the person at the iPad (the code and the Allow prompt) and the person at the Mac (the
plugin window).

Known limits of this first version, stated plainly:

- **The pairing code is short (40 bits).** Someone who records the pairing exchange can try codes offline; each guess
  costs a 200 000-iteration PBKDF2, so about 2⁴⁰ × 2×10⁵ HMAC operations for the whole space. That is costly but not out
  of reach for a determined attacker, who would then learn that Mac's key. The window is short (3 minutes, one Mac). A
  password-authenticated key exchange (SPAKE2 or similar) would remove this; Apple's frameworks offer none we can use
  from both a plugin and an app without adding a cryptography dependency.
- **No forward secrecy:** TLS 1.2 PSK without (EC)DHE. Whoever later obtains a stored key can decrypt recorded traffic of
  that pair. The traffic is measurements, never audio.
- Paired Macs are equal: a paired Mac can claim another device ID or computer name in its HELLO (the display shows names
  as sent). The PSK identity is not yet bound to the HELLO device ID. Reviewed for build 2: Network.framework does not
  report which pre-shared key a server-side handshake used, so the binding needs either one listener per paired Mac or
  a key-confirmation field in HELLO (an HMAC of the session over the pairing key); both are protocol changes left for a
  versioned extension.
- The iPad's name and receiver ID are visible to anyone browsing the local network.
- TLS 1.2 PSK cipher suites are supported by Network.framework today (iOS 12+, macOS 10.14+) but are not TLS 1.3; a later
  version should move to TLS 1.3 external PSK when both ends can.

## Not in this version

Multi-FFT over the network (it needs audio, which the Bridge never sends: the display shows the Bridge spectrum, 64 and
128 bands), simultaneous Mac and iPad display of one instance, several iPads per instance, internet relays, accounts.
Since build 2 the spatial field, observations and SPATIAL_CONFIG reach the iPad (Build 120's receiver and SoundStage). Any expanded analysis payload will be an explicit, versioned extension of PROTOCOL.md.
