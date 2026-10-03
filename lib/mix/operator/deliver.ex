defmodule Mix.Operator.Deliver do
  @moduledoc """
  The Mac side of Operator's over-the-air updates (`Operator.Deliver` is
  the phone's), shared by `mix operator.deliver.key`, `mix
  operator.deliver.serve`, `mix operator.deliver.qr` and `mix
  operator.publish`. Dev-only: mob_deliver_server and Bandit exist only in
  `:dev` and `:test`, and these modules are never published to the phone.

    * Signing key: `~/.config/operator/deliver_signing.key` (`key_path/0`,
      mode 0600). `config/config.exs` bakes its public half into every
      build as mob_deliver's trust root.
    * Store: `~/.local/share/operator/deliver/` (`store_root/0`), served at
      `http://<the Mac's LAN address>:8040/deliver` on the home network.

  ## What a publish delivers (`build/1`)

  Operator's own modules: the BEAMs `mix compile` wrote to the compile
  path, the same files `mix mob.deploy` ships (Core, screens, tools, ...),
  so a publish carries whatever changed since the build on the phone. Each
  is stripped to the chunks the VM needs, as mob_deliver_server does, so
  an unchanged module keeps its SHA wherever the checkout lives (debug info
  and docs embed its path) and phones don't download it again. Left out,
  so the phone keeps the build's copy (`publishable?/2`):

    * `:mob_app_config`: the build's config, the update trust root in it
      (mob_deliver refuses a manifest that carries it);
    * `:operator`: the BEAM entry module, which runs before mob_deliver
      loads anything, so a delivered copy would never run at launch;
    * modules that call `:erlang.load_nif/2` (`Operator.Nifs.*`): they bind
      to the native code inside the installed binary;
    * `Mix.*`: these Mac-side tasks.

  Never deliverable (not in the app's compile path): dependencies (mob,
  mob_dev, the plugins, jido, ...), native code, `priv/` (migrations,
  fonts, models), `config/*.exs` and `mob.exs`. Delivered code runs against
  the deps, NIFs and config already on the phone, so a change that needs
  any of them (a new migration, dependency or plugin) needs a native
  deploy first, then a publish from the same checkout.
  """

  alias MobDeliverServer.Storage.FS

  @key_path "~/.config/operator/deliver_signing.key"
  @store_root "~/.local/share/operator/deliver"
  @port 8040
  # Bundled-only modules, by manifest key (see the moduledoc).
  @bundled_only [":mob_app_config", ":operator"]

  @spec key_path() :: Path.t()
  def key_path, do: Path.expand(@key_path)

  @spec store_root() :: Path.t()
  def store_root, do: Path.expand(@store_root)

  @spec default_port() :: pos_integer()
  def default_port, do: @port

  @doc "The update server URL the phone uses for `ip` and `port`."
  @spec endpoint(String.t(), pos_integer()) :: String.t()
  def endpoint(ip, port), do: "http://#{ip}:#{port}/deliver"

  # ── the signing key ──

  @doc """
  Writes `private_key` to `path` with mode 0600, never over an existing
  file (a new key would strand every phone built with the old one).
  """
  @spec write_private_key(Path.t(), String.t()) :: :ok | {:error, :exists | File.posix()}
  def write_private_key(path, private_key) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, io} <- open_new(path) do
      try do
        # Restricted before the key is in it.
        with :ok <- File.chmod(path, 0o600), do: IO.binwrite(io, private_key <> "\n")
      after
        File.close(io)
      end
    end
  end

  defp open_new(path) do
    case File.open(path, [:write, :exclusive]) do
      {:error, :eexist} -> {:error, :exists}
      other -> other
    end
  end

  @doc "The signing key in `path` (key-file form), or a Mix error saying what to do."
  @spec read_private_key!(Path.t()) :: String.t()
  def read_private_key!(path \\ key_path()) do
    with {:ok, contents} <- File.read(path),
         key = String.trim(contents),
         {:ok, _seed} <- MobDeliverServer.Manifest.decode_private_key(key) do
      key
    else
      {:error, :enoent} ->
        Mix.raise(
          "No signing key at #{path}: run `mix operator.deliver.key`, then deploy natively " <>
            "once (`mix mob.deploy --native --android`) so the phone trusts it."
        )

      {:error, :malformed_key} ->
        Mix.raise("#{path} isn't a signing key (ed25519-private:<base64>)")

      {:error, reason} ->
        Mix.raise("Can't read #{path}: #{:file.format_error(reason)}")
    end
  end

  @doc ~S|The public half of `private_key`, as the build's trust root: `"ed25519:" <> base64`.|
  @spec public_key(String.t()) :: String.t()
  def public_key(private_key), do: MobDeliverServer.Manifest.public_key_string(private_key)

  # ── the Mac's address ──

  @doc """
  The Mac's address on the home network: a private IPv4 address of an
  interface that is up; the default route's interface first (the network
  the Mac, and so the phone, reaches the internet on), then Wi-Fi and
  Ethernet (`en*`), then the rest (VPN tunnels, VM bridges). `nil` when
  there is none.
  """
  @spec lan_ip({:ok, list()} | {:error, term()}, String.t() | nil) :: String.t() | nil
  def lan_ip(ifaddrs \\ :inet.getifaddrs(), default \\ default_interface()) do
    with {:ok, interfaces} <- ifaddrs,
         [{_rank, ip} | _] <-
           interfaces |> Enum.flat_map(&private_ipv4s(&1, default)) |> Enum.sort() do
      ip |> :inet.ntoa() |> to_string()
    else
      _ -> nil
    end
  end

  @doc "The default route's interface (`route -n get default`, macOS), or `nil`."
  @spec default_interface() :: String.t() | nil
  def default_interface do
    with path when is_binary(path) <- System.find_executable("route"),
         {out, 0} <- System.cmd(path, ["-n", "get", "default"], stderr_to_stdout: true),
         [_, name] <- Regex.run(~r/interface:\s*(\S+)/, out) do
      name
    else
      _ -> nil
    end
  end

  defp private_ipv4s({name, opts}, default) do
    name = to_string(name)
    up? = :up in Keyword.get(opts, :flags, [])

    for {:addr, {a, b, _, _} = ip} <- opts,
        up?,
        private?(a, b),
        do: {{rank(name, default), name}, ip}
  end

  defp private?(10, _), do: true
  defp private?(172, b), do: b in 16..31
  defp private?(192, 168), do: true
  defp private?(_, _), do: false

  defp rank(default, default), do: 0
  defp rank("en" <> _, _default), do: 1
  defp rank(_other, _default), do: 2

  # ── publishing ──

  @doc """
  The publishable modules in `ebin_dir` as a `MobDeliverServer.build()`:
  `%{module_key => {sha256, stripped_beam}}` (see the moduledoc).
  """
  @spec build(Path.t()) :: %{String.t() => {String.t(), binary()}}
  def build(ebin_dir) do
    for path <- Path.wildcard(Path.join(ebin_dir, "*.beam")),
        beam = path |> File.read!() |> strip(),
        {:ok, {module, []}} = :beam_lib.chunks(beam, []),
        key = MobDeliverServer.module_key(module),
        publishable?(key, beam),
        into: %{},
        do: {key, {sha256(beam), beam}}
  end

  @doc "Whether the module with manifest key `key` and code `beam` is published (see the moduledoc)."
  @spec publishable?(String.t(), binary()) :: boolean()
  def publishable?(key, beam) do
    key not in @bundled_only and not String.starts_with?(key, "Mix.") and not nif_stub?(beam)
  end

  defp nif_stub?(beam) do
    {:ok, {_module, [imports: imports]}} = :beam_lib.chunks(beam, [:imports])
    {:erlang, :load_nif, 2} in imports
  end

  @doc "`beam` reduced to the chunks the VM needs to load and run it (as `MobDeliverServer.build/2` strips)."
  @spec strip(binary()) :: binary()
  def strip(beam) do
    {:ok, {_module, chunks}} =
      :beam_lib.chunks(beam, [~c"Attr" | :beam_lib.significant_chunks()], [:allow_missing_chunks])

    {:ok, stripped} =
      :beam_lib.build_module(for {_id, data} = chunk <- chunks, is_binary(data), do: chunk)

    stripped
  end

  defp sha256(binary), do: Base.encode16(:crypto.hash(:sha256, binary), case: :lower)

  @doc """
  Signs `build` and stores it with its manifest under `opts[:root]` for
  `opts[:app]` / `opts[:channel]`, then reports what changed against the
  manifest it replaced: `{:ok, %{fields: manifest_fields, changed:
  [{"added" | "changed", key}], removed: [key], previous_issued_at:}}`.
  """
  @spec publish(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def publish(build, opts) do
    storage = {FS, root: Keyword.fetch!(opts, :root)}
    app = Keyword.fetch!(opts, :app)
    channel = Keyword.fetch!(opts, :channel)

    with {:ok, {previous_issued_at, previous}} <- previous(storage, app, channel),
         {:ok, %{fields: fields}} <-
           MobDeliverServer.publish(build,
             app: app,
             channel: channel,
             private_key: Keyword.fetch!(opts, :private_key),
             storage: storage
           ) do
      modules = fields["modules"]

      changed =
        for {key, sha} <- Enum.sort(modules), previous[key] != sha, do: change(key, previous)

      removed = previous |> Map.keys() |> Enum.reject(&Map.has_key?(modules, &1)) |> Enum.sort()

      {:ok,
       %{
         fields: fields,
         changed: changed,
         removed: removed,
         previous_issued_at: previous_issued_at
       }}
    end
  end

  defp change(key, previous),
    do: if(Map.has_key?(previous, key), do: {"changed", key}, else: {"added", key})

  # The manifest this publish replaces, for the report only (nothing in it
  # is trusted).
  defp previous({FS, config}, app, channel) do
    case FS.get_manifest(config, app, channel) do
      {:ok, body} ->
        manifest = JSON.decode!(body)
        {:ok, {manifest["issued_at"], manifest["modules"]}}

      {:error, :not_found} ->
        {:ok, {nil, %{}}}

      {:error, reason} ->
        {:error, {:previous_manifest, reason}}
    end
  end
end

defmodule Mix.Operator.Deliver.Server do
  @moduledoc """
  What `mix operator.deliver.serve` runs under Bandit: mob_deliver's wire
  (`POST /deliver/manifest`, `GET /deliver/beam/:sha256`, from
  `MobDeliverServer.Plug`) and nothing else, each request logged with the
  phone's address. Options: those of `MobDeliverServer.Plug` (`:storage`).
  """
  @behaviour Plug

  @impl Plug
  def init(opts), do: MobDeliverServer.Plug.init(opts)

  @impl Plug
  def call(%Plug.Conn{path_info: ["deliver" | rest]} = conn, deliver_opts) do
    conn
    |> Plug.Conn.register_before_send(&log/1)
    |> Plug.forward(rest, MobDeliverServer.Plug, deliver_opts)
  end

  def call(conn, _opts), do: conn |> Plug.Conn.send_resp(404, "") |> Plug.Conn.halt()

  defp log(conn) do
    from = conn.remote_ip |> :inet.ntoa() |> to_string()
    Mix.shell().info("#{from} #{conn.method} #{conn.request_path} #{conn.status}")
    conn
  end
end
