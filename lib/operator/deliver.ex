defmodule Operator.Deliver do
  @moduledoc """
  Over-the-air updates of Operator's own code: the phone's side of the
  Core's release path (docs/DESIGN.md §1). The Mac publishes the app's
  compiled modules, signed (`mix operator.publish`), and serves them on the
  home network (`mix operator.deliver.serve`); mob_deliver, a mob plugin,
  checks for them at launch, every 5 minutes in the foreground and from
  Diagnostics, verifies the signature against the key baked into this build
  (`config :mob_deliver, :trusted_publish_key`) and loads them from the next
  launch on.

  **The endpoint isn't baked into the build**: the Mac's address changes.
  The phone learns it from a QR (`mix operator.deliver.qr`):
  `operator://deliver?endpoint=…&key=…` (`link/2`, handled by
  `Operator.Links`, then `configure/2`) carries the server's URL and the
  fingerprint of the key it signs with, which must be this build's trusted
  key or the link is refused. The endpoint is kept in
  `Operator.Core.Settings` and put into mob_deliver's environment
  (`config :mob_deliver, :endpoint`, read on every check): at launch by
  `apply_saved_endpoint/1`, which `src/operator.erl` runs before mob starts
  its plugins, and at once when a link sets it. mob_deliver doesn't start
  without an endpoint, so on a phone that had none at launch the first scan
  asks for a restart.

  **One stable launch for both layers.** mob_deliver keeps a new update on
  probation until a launch running it is stable, and rolls it back at the
  next launch otherwise; the Dyn Keeper does the same for a new generation
  (`Operator.Core.Dyn.Keeper`). mob_deliver's own proof is the root
  screen's first frame, the Keeper's is the first frame and then 10 s or the
  user leaving. `take_over_probation/0` removes mob_deliver's proof and the
  Keeper calls `launch_stable/0` instead, so a Core update that crashes the
  app in those 10 s is rolled back too. A launch whose update mob_deliver
  rolled back failed on the Core, not on the Dyn layer:
  `rolled_back_this_launch?/1` tells the Keeper not to count it
  (`Operator.Core.Dyn.boot/1`).
  """

  alias Operator.Core.Settings

  require Logger

  @booted_key {__MODULE__, :endpoint_at_launch}
  # What mob_deliver's plugin start registers to end a probation at the
  # root screen's first frame (MobDeliver.Hooks.register/0).
  @first_frame_proof {MobDeliver.Hooks, :first_render, []}

  @typedoc "What Diagnostics shows; see `status/0`."
  @type status :: %{
          endpoint: String.t() | nil,
          running: boolean(),
          active: %{id: String.t(), issued_at: DateTime.t()} | nil,
          last_check: %{result: term(), at: DateTime.t()} | nil,
          restart_required: boolean(),
          rollback: %{rolled_back: String.t(), at: DateTime.t()} | nil
        }

  # ── the link ──

  @doc """
  The `operator://deliver` link for an update server at `endpoint` signing
  with `public_key` (`"ed25519:" <> base64`, as `mob_deliver_server` prints
  it).
  """
  @spec link(String.t(), String.t()) :: String.t()
  def link(endpoint, public_key) do
    {:ok, fingerprint} = fingerprint(public_key)
    "operator://deliver?" <> URI.encode_query(%{"endpoint" => endpoint, "key" => fingerprint})
  end

  @doc """
  The fingerprint a link carries for `public_key`: the SHA-256 of the raw
  32-byte key, base64url without padding.
  """
  @spec fingerprint(String.t()) :: {:ok, String.t()} | :error
  def fingerprint("ed25519:" <> encoded) do
    case Base.decode64(encoded) do
      {:ok, <<raw::binary-size(32)>>} ->
        {:ok, Base.url_encode64(:crypto.hash(:sha256, raw), padding: false)}

      _ ->
        :error
    end
  end

  def fingerprint(_key), do: :error

  @doc """
  Acts on an `operator://deliver` link's parameters: refuses an endpoint
  that isn't an http(s) URL, or whose key fingerprint isn't this build's
  trusted key's; otherwise saves it in `dir`'s settings, hands it to
  mob_deliver and (when its update checks run) checks for an update.
  Returns the sentence to show.
  """
  @spec configure(%{String.t() => String.t()}, String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def configure(params, dir \\ Operator.Paths.data_dir()) do
    with {:ok, endpoint} <- endpoint(params["endpoint"]),
         :ok <- trusted?(params["key"]) do
      :ok = Settings.put_deliver_endpoint(endpoint, dir)
      put_endpoint(endpoint)

      if checks_running?() do
        {:ok, _} = Task.start(&MobDeliver.check/0)
        {:ok, "Update server set to #{endpoint}: checking for updates."}
      else
        {:ok,
         "Update server set to #{endpoint}. Close Operator and open it again to start " <>
           "checking for updates."}
      end
    end
  end

  defp endpoint(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}} when scheme in ["http", "https"] and host != "" ->
        {:ok, url}

      _ ->
        {:error, "That update-server code has no valid address."}
    end
  end

  defp endpoint(_url), do: {:error, "That update-server code has no valid address."}

  defp trusted?(key) do
    case trusted_key() && fingerprint(trusted_key()) do
      {:ok, ^key} ->
        :ok

      {:ok, _other} ->
        {:error,
         "That update server signs with another key than this build trusts: not saved. " <>
           "Is it this Mac's `mix operator.deliver.serve`?"}

      _none ->
        {:error,
         "This build has no update key: run `mix operator.deliver.key` on the Mac, then " <>
           "deploy natively once (`mix mob.deploy --native`)."}
    end
  end

  # The trust root the build was made with (mob_dev ships config/config.exs
  # into the build; mob_deliver itself reads it from there).
  defp trusted_key, do: Application.get_env(:mob_deliver, :trusted_publish_key)

  # ── launch ──

  @doc """
  Puts the endpoint saved in `dir`'s settings into mob_deliver's
  environment. Run by `src/operator.erl` before `Operator.App.start/0`, so
  before mob starts its plugins: mob_deliver only starts (and checks at
  launch) with an endpoint set. Persistent, so loading the `:mob_deliver`
  application doesn't reset it.
  """
  @spec apply_saved_endpoint(String.t()) :: :ok
  def apply_saved_endpoint(dir \\ Operator.Paths.data_dir()) do
    endpoint = Settings.deliver_endpoint(dir)
    if endpoint, do: put_endpoint(endpoint)
    :persistent_term.put(@booted_key, endpoint)
    :ok
  end

  defp put_endpoint(endpoint),
    do: Application.put_env(:mob_deliver, :endpoint, endpoint, persistent: true)

  # mob_deliver started its update checks this launch: it had an endpoint.
  defp checks_running?, do: :persistent_term.get(@booted_key, nil) != nil

  @doc """
  Makes the Dyn Keeper's stable launch the only proof of a delivered
  update: removes mob_deliver's own (the root screen's first frame). Run by
  `Operator.Boot`, after mob_deliver's start registered it and before the
  root screen renders.
  """
  @spec take_over_probation() :: :ok
  def take_over_probation,
    do: Mob.Router.Hooks.unregister(:after_first_render, @first_frame_proof)

  @doc """
  The launch is stable (`Operator.Core.Dyn.Keeper`'s `:on_stable`): ends a
  delivered update's probation. A no-op without mob_deliver or an update.
  """
  @spec launch_stable() :: :ok
  def launch_stable do
    with {:error, reason} when reason != :not_running <- MobDeliver.mark_stable() do
      Logger.error("mob_deliver couldn't record the stable launch: #{inspect(reason)}")
    end

    :ok
  end

  @doc """
  Whether mob_deliver rolled an update back during this launch (its
  `notice`, `MobDeliver.rollback_notice/0`, is newer than the VM): the last
  launch crashed in a Core update, which is gone now.
  """
  @spec rolled_back_this_launch?(map() | nil) :: boolean()
  def rolled_back_this_launch?(notice \\ MobDeliver.rollback_notice()) do
    case notice do
      %{at: %DateTime{} = at} -> DateTime.compare(at, vm_started_at()) != :lt
      _ -> false
    end
  end

  defp vm_started_at do
    {uptime_ms, _since_last_call} = :erlang.statistics(:wall_clock)
    DateTime.add(DateTime.utc_now(), -uptime_ms, :millisecond)
  end

  # ── Diagnostics ──

  @doc """
  The update state for Diagnostics: the endpoint, whether update checks run
  this launch, the delivered code running (`active`: the installed
  manifest, `nil` for the build's own code), the last check, whether an
  installed update waits for the next launch, and a rollback notice. Reads
  stored code to tell `restart_required`: call it off the screen process.
  """
  @spec status() :: status()
  def status do
    state = MobDeliver.state()

    %{
      endpoint: Application.get_env(:mob_deliver, :endpoint),
      running: state.running and checks_running?(),
      active: state.active,
      last_check: state.last_check,
      restart_required: state.restart_required,
      rollback: state.rollback_notice
    }
  end

  @doc """
  Checks for an update now (`MobDeliver.check/1`). Blocks for the download:
  call it off the screen process.
  """
  @spec check() ::
          {:ok, MobDeliver.check_outcome(), %{restart_required: boolean()}} | {:error, term()}
  def check, do: MobDeliver.check(details: true)

  @doc "Clears the rollback notice Diagnostics shows."
  @spec dismiss_rollback() :: :ok
  def dismiss_rollback do
    _ = MobDeliver.take_rollback_notice()
    :ok
  end

  @doc "`status/0` as the lines Diagnostics shows."
  @spec status_lines(status()) :: [String.t()]
  def status_lines(status) do
    [
      server_line(status.endpoint),
      running_line(status.active),
      check_line(status.last_check),
      status.endpoint && not status.running && "Update checks start at the next launch.",
      status.restart_required &&
        "An installed update is waiting: close Operator and open it again to run it.",
      rollback_line(status.rollback)
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp server_line(nil),
    do:
      "Update server: not set. On the Mac: mix operator.deliver.serve, then scan " <>
        "mix operator.deliver.qr (Scan QR above)."

  defp server_line(endpoint), do: "Update server: #{endpoint}"

  defp running_line(nil), do: "Running: this build's own code"

  defp running_line(%{id: id, issued_at: issued_at}),
    do: "Running: update #{short(id)}, published #{stamp(issued_at)}"

  defp check_line(nil), do: "Last check: none since launch"
  defp check_line(%{result: result, at: at}), do: "Last check (#{stamp(at)}): #{describe(result)}"

  defp rollback_line(nil), do: nil

  defp rollback_line(%{rolled_back: id, at: at}),
    do: "Update #{short(id)} didn't reach a stable launch and was rolled back (#{stamp(at)})."

  @doc "A check's result (`check/0`, `MobDeliver.check/0`) in words."
  @spec describe(term()) :: String.t()
  def describe({:ok, outcome, _details}), do: describe({:ok, outcome})
  def describe({:ok, :current}), do: "up to date"
  def describe({:ok, :installed}), do: "update installed: it runs from the next launch"

  def describe({:ok, :deferred}),
    do: "an installed update hasn't had its stable launch yet: checking again after it"

  def describe({:ok, :rejected}),
    do: "the published update was rolled back on this phone before: publish a fixed one"

  def describe({:ok, :stale_for_build}),
    do: "the published code is older than this build: publish again from this checkout"

  def describe({:ok, :below_min_version}),
    do: "the published update needs a newer build: deploy natively"

  def describe({:error, :not_configured}), do: "no update server set"

  def describe({:error, :not_running}),
    do: "update checks aren't running: close Operator and open it again"

  def describe({:error, {:transport, _}}),
    do: "can't reach the update server: is mix operator.deliver.serve running on the Mac?"

  def describe({:error, {:http_status, 404}}),
    do: "nothing published yet: mix operator.publish on the Mac"

  def describe({:error, :invalid_signature}),
    do: "the server's update isn't signed with this build's key"

  def describe(other), do: "failed: #{inspect(other, limit: 5, printable_limit: 120)}"

  defp short(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short(id), do: inspect(id)

  defp stamp(%DateTime{} = at),
    do: at |> DateTime.truncate(:second) |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")
end
