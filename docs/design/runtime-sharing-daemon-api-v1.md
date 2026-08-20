# Runtime Sharing Daemon API v1

AgentKit's `RuntimeSharingDaemonClient` is the macOS App control-plane client
for a Code-Agent daemon. The daemon, not the App, owns the shared listener,
TLS identity, Bonjour publisher, bootstrap state and paired-device registry.

The management API is intended for localhost access. If the daemon requires a
credential, the App sends it as a Bearer token. Management endpoints must not
be exposed as unauthenticated LAN endpoints.

All JSON responses use the existing Runtime envelope:

```json
{"code": 0, "msg": "success", "data": {}}
```

## Endpoints

### Start sharing

```text
POST /v1/runtime/sharing/start
```

Request:

```json
{
  "display_name": "My Mac",
  "listen_address": "0.0.0.0:0"
}
```

Both fields are optional. The response `data` is
`RuntimeSharedListenerStatus`.

### Stop sharing

```text
POST /v1/runtime/sharing/stop
```

The daemon must complete the listener shutdown before returning a successful
response. The response data may be `null`.

### Read status

```text
GET /v1/runtime/sharing/status
```

The response `data` is `RuntimeSharedListenerStatus`.

### Create pairing invitation

```text
POST /v1/runtime/sharing/invitations
```

Request:

```json
{"validity_seconds": 120}
```

The daemon clamps validity to its supported range, generates the bootstrap
secret, stores only its SHA-256 digest, and returns a
`RuntimePairingInvitation` in `data`.

### List paired devices

```text
GET /v1/runtime/sharing/devices
```

Response data:

```json
{"devices": []}
```

The response must never include a plaintext device credential.

### Revoke a device

```text
DELETE /v1/runtime/sharing/devices/{device_id}
```

The daemon must persist the revocation before updating its live validation
table. A successful response means the live table has also been updated.
