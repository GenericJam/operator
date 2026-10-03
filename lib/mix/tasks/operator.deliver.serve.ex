defmodule Mix.Tasks.Operator.Deliver.Serve do
  @shortdoc "Serves Operator's code updates to the phone on the home network"
  @moduledoc """
  Serves what `mix operator.publish` stored to the phone, on the home
  network (all interfaces, plain HTTP: the manifest is signed and every
  module checked against it on the phone):

      mix operator.deliver.serve              # port 8040
      mix operator.deliver.serve --port 8041

  mob_deliver's wire (`MobDeliverServer.Plug` under `/deliver`, Bandit),
  from `~/.local/share/operator/deliver/` (`--store DIR` for another
  store). Each request is logged with the phone's address. Runs until
  interrupted (Ctrl-C twice). Point the phone at it with `mix
  operator.deliver.qr` (same `--port`).

  Doesn't start the Operator application.
  """
  use Mix.Task

  alias Mix.Operator.Deliver

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [port: :integer, store: :string])
    port = Keyword.get(opts, :port, Deliver.default_port())
    store = opts |> Keyword.get(:store, Deliver.store_root()) |> Path.expand()
    File.mkdir_p!(store)

    {:ok, _} = Application.ensure_all_started(:bandit)

    {:ok, _} =
      Bandit.start_link(
        plug: {Deliver.Server, storage: {MobDeliverServer.Storage.FS, root: store}},
        ip: {0, 0, 0, 0},
        port: port,
        startup_log: false
      )

    address =
      case Deliver.lan_ip() do
        nil -> "no LAN address found"
        ip -> Deliver.endpoint(ip, port)
      end

    Mix.shell().info("""
    Serving Operator's code updates from #{store}
    at #{address} (Ctrl-C twice to stop).
    Phone: scan mix operator.deliver.qr#{port_arg(port)}. Publish: mix operator.publish.
    """)

    Process.sleep(:infinity)
  end

  defp port_arg(port) do
    if port == Deliver.default_port(), do: "", else: " --port #{port}"
  end
end
