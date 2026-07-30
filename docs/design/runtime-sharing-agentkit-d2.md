# Runtime Sharing — AgentKit D2

Status: implemented, awaiting chater D3 integration.

## Mac host

`RuntimeSharingController` owns the host-side control plane:

- starts/stops the CodeAgent Shared TLS Listener;
- creates a persistent P-256 TLS identity in Keychain;
- advertises `_talkify-agent._tcp.` through Bonjour;
- creates short-lived `RuntimePairingInvitation` payloads;
- polls pending enrollments and persists the credential hash before ack;
- stores only device validation hashes and metadata;
- revokes a device through a durable tombstone plus Runtime hot update.

The Embedded loopback endpoint and its temporary access token are unchanged and
are never included in an invitation.

## iPhone client

`RuntimeBonjourBrowser` discovers shared Mac Runtimes. The QR payload remains the
authority for `server_id`, bootstrap secret and SPKI pin; Bonjour only resolves
the current hostname and port.

`RuntimeServerCoordinator.pairSharedRuntime(...)`:

1. sends the one-time bootstrap request over pinned TLS;
2. receives the device credential after the Mac durable-ack;
3. runs Info, Capabilities and Models preflight using the device credential;
4. verifies `server_id`;
5. saves the credential in the existing Runtime Access Keychain;
6. registers a Server-scoped connection containing the SPKI trust policy.

The same trust policy is applied to HTTP, conversation Agent Wire, Job Stream
and Child Stream connections.

## chater D3 integration

- macOS: own one `RuntimeSharingController`, expose sharing toggle, pairing QR,
  status, paired devices and revoke.
- iOS: scan/decode `RuntimePairingInvitation`, resolve the matching Bonjour
  record when available, then call `pairSharedRuntime`.
- Add `_talkify-agent._tcp.` to `NSBonjourServices` and keep the existing Local
  Network usage description.
- Do not render `listen_origin` as a QR or Bonjour endpoint; it is diagnostic
  and may contain `0.0.0.0` or `[::]`.
