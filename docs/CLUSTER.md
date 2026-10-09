# Operator local clusters

Operator 1.1 can join phones and headless BEAM devices on one private LAN. Clustering is **off by default**. When off, a release build has no distribution listener; a development build keeps only mob's loopback development link.

## Pair two Operators

1. Connect both devices to the same private Wi-Fi network.
2. On the first device, open `[menu] › cluster` and enable the cluster. TLS distribution starts right away; no restart.
3. Choose **show invite**. Pairing remains open for five minutes.
4. On the second device, open `[menu] › cluster › scan invite` and scan the first device's QR.
5. Compare the displayed node and certificate fingerprint. Approve with the second device's system screen lock.
6. Both cluster pages list the connected peer. Close pairing on the first device.

The QR is a secret. It contains the inviter's node, pinned certificate fingerprint, fixed port, the distribution cookie, and that pairing window's one-off secret. Each invite makes a new cookie and hands it to every member connected at that moment, so an earlier QR stops working at the next invite. Do not send it through chat, screenshots, logs, or a public network. A member that was offline when an invite or a forget changed the cookie can't reconnect until it scans a fresh invite from any member it already knows.

**Forget** disconnects and revokes a peer and replaces the cluster cookie, here and on every member connected now, so the forgotten device can no longer pass distribution's handshake even while a later pairing window is open; a member that was offline then rejoins by scanning a fresh invite from any member it already knows. Revocations are gossiped among reachable members and are not resurrected by later membership gossip. Each pairing window also has its own secret, which only that window's QR carries: a new certificate is pinned only by a peer that presents it. `Operator.Cluster.reset/0` turns clustering off, deletes the cluster identity and cookie, and forgets all peers.

## Security boundary

- TLS 1.3 with a self-signed certificate per installation. The exact certificate fingerprint is pinned; system certificate authorities are not trusted for membership.
- Mutual certificates. During the five-minute pairing window only, the inviter may admit an unpinned certificate as pending. It becomes a member only after proving possession of the QR's random Erlang cookie and presenting that window's secret along with the same certificate fingerprint.
- One fixed TCP port, `9370`, bound to the current private-LAN address. No epmd listener. Address changes restart distribution with a new node address.
- Secrets: the private key and cookie use Android Keystore / iOS Keychain through `Operator.SecureStore`. Non-secret peer and revocation records live under the app data directory.
- The cluster is local-network infrastructure, not an Internet transport. There is no relay, NAT traversal, hostname authentication, or public discovery.
- At most 32 members and 64 identities (members plus revocations) are retained; a peer that would exceed them is disconnected, not admitted. A phone already joined to a cluster refuses an invite carrying a different cluster cookie; reset it deliberately before moving it to another cluster.

A trusted Erlang distribution peer has the authority of the app. It can send ordinary distribution messages and can invoke BEAM facilities such as RPC; `Operator.Cluster.Bus` is a small stable application API, **not a sandbox against a malicious member**. Pair only devices and firmware you control.

## The agents talk to each other

Each Operator's agent has a `cluster` tool (`Operator.Core.Tools.Cluster`):

- `peers`: this phone's node and each paired one, connected or not.
- `tool`: runs one of a peer's agent tools on that phone and returns the result: its `location`, `sensors` (battery, motion, ...), a `notify` there, its `clipboard`, `notes`, files, `http_get`, `camera_snap`. Pictures stay on that phone (a Bus reply is at most 64 KiB). The peer runs only an allowlist of its Core tools (`Operator.Cluster.Remote.remote?/1`): `notes`, `friction`, `http_get`, `clipboard`, `location`, `notify`, `camera_photo`, `camera_snap`, `pick_photos`, `photos_recent`, `sensors`, the `file_*` tools, `dyn_files`, `dyn_read`, `dyn_status`, `front_screens`, `front_screenshot`, `read_guide` and `read_doc`, plus the tools of its current Dyn generation. Everything else is refused: tools that change the peer's own app (Dyn writes, `dyn_propose`, `front_open`, `front_tap`, `front_send`), that reach into it (`eval`, `logs`) or rewrite its agent's instructions (`instructions`, `skill`), that only make sense in one session (`read_artifact`, `todo`, `task`), `cluster` itself, and any Core tool added later until it is put on the list.
- `ask`: gives a text to the peer's agent and returns its answer. On the peer it becomes the next user message of its current session (`<node> asks: …`): a run starts if the agent is idle, otherwise it is answered when the current run would stop. The answer is that run's last text. Past 110 s the asker hears "still working" and the answer arrives later as a `message`.
- `message`: shows a text in the peer's terminal (an `»` notice its agent also reads on its next turn) and as a notification there. It doesn't start a run.

An exchange is one question and one answer: while a session is answering a peer's question, its agent can't `ask` anyone, so two agents can't keep waking each other. A peer gets one question answered at a time, and a phone answers at most three at once.

The peer side is `Operator.Cluster.Remote`, three Bus services (`operator.tool`, `operator.message`, `operator.ask`), so only members reach it. On 2026-10-08 the Moto's agent, asked to, listed the peers, read the iPhone's battery with `sensors` and sent it a message; later, asked to get a joke from the other phone, it called `ask` and the iPhone's agent answered in 3 s with nobody touching the iPhone.

## Application API

Front screens and embedded services should use `Operator.Cluster.Bus` rather than depending on Operator's internal process names:

```elixir
alias Operator.Cluster.Bus

:ok = Bus.subscribe("workshop/temperature")
:ok = Bus.publish("workshop/temperature", %{celsius: 21.4})

:ok = Bus.register("sensor.read")
# The registered process receives {:cluster_call, {caller, ref}, request}
# and answers with Bus.reply({caller, ref}, response).

{:ok, response} = Bus.call(peer_node, "sensor.read", %{sensor: :ambient})
```

Topic and service names are 1–100 bytes. Messages must be external-term encodable, contain no functions, and encode to at most 64 KiB. Calls target only a process registered for that service. Publish/subscribe uses a named `:pg` scope across the cluster.

## Headless/Nerves path

The wire protocol is normal distributed Erlang with Operator's TLS pinning and membership handshake. A Nerves device therefore needs:

1. persistent EC identity and cluster cookie storage appropriate to the board;
2. `Operator.Cluster.Identity`, `Tls`, `Invite`, `Bus`, `:operator_dist`, and `:operator_epmd` (these should become a small standalone dependency before product use; depending on the whole mobile app is not recommended);
3. one VM argument at boot, the only part of distribution OTP takes from the command line (net_kernel picks the carrier module from it):

   ```text
   -proto_dist operator
   ```

   Everything else is set at run time by `Operator.Cluster.prepare_node/0` before `Node.start/2`: the TLS options (into the `ssl_dist_opts` table `inet_tls_dist` reads, instead of an `-ssl_dist_optfile`) and global's `connect_all false`;

4. a private-LAN address, TCP port 9370, and an invite-confirmation policy suitable for the device (for example, a physical button plus a phone-displayed fingerprint instead of a phone screen lock).

For Nerves, put the VM arguments in the release's `vm.args.eex` and persist identity/state under `/data`. If the target needs a custom `erlinit.config`, follow Nerves' root-filesystem overlay guidance and start from the target system's original file rather than replacing it blindly: <https://hexdocs.pm/nerves/advanced-configuration.html#root-filesystem-overlays>.

### Desktop stand-in

`scripts/cluster_peer.exs` is a headless peer with one `nerves.echo` service. It runs the same custom distribution modules and handshake from this checkout, providing a cheap protocol stand-in before building firmware. It pins only its inviter and ignores membership gossip and cookie changes, so it forms a two-node cluster with that phone and needs a fresh invite after the phone makes another one; it is not a full member of a larger cluster.

From the Operator checkout:

```sh
export MOB_DATA_DIR="$PWD/_build/cluster_peer"

# Obtain a fresh five-minute operator://cluster invite from the phone.
elixir --erl "-proto_dist operator" \
  -S mix run --no-start scripts/cluster_peer.exs 'operator://cluster?...'
```

Approve the stand-in while the inviter's pairing window is open. From the inviting phone, `Operator.Cluster.Bus.call(headless_node, "nerves.echo", term)` returns `{:ok, {:nerves_echo, term}}`.

This probe establishes transport and API compatibility; it does not claim Nerves power-loss behavior, secure-element integration, Wi-Fi roaming, or firmware-update safety. Those require a real target and should gate extraction of the standalone cluster dependency.

## Operations

- `-proto_dist operator` must be on the BEAM's command line from the first launch: the native hosts (`MainActivity`, `AppDelegate`) write it to `Mob.InitArgs`' file before starting the BEAM. Without it (an install of an older build, first launch only) enabling asks for one restart. A native build with mob 0.9.13 or newer is required.
- While clustering is on, it replaces mob's development distribution link. Use cluster membership for remote inspection; disabling restores the loopback development link in a development build.
- Members may reach each other one way only (two Wi-Fi networks behind one router: on 2026-10-08 the iPhone reached the Moto but not the reverse). A member dials a peer only after a plain TCP connect to its port 9370 succeeds. Otherwise a dial that can never arrive stays pending, and while it does, distribution turns away the peer's own dial (the node with the greater name keeps its own attempt), so the two would never link. While joining, a failed dial is logged with its reason.
- Certificate fingerprints are SHA-256 lowercase hex. Node names and cookie strings are validated and bounded before approval; atoms are created only after the system-lock approval path.
- Do not expose port 9370 with router port forwarding. Host firewalls should restrict it to the private LAN.
