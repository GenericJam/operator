defmodule Mix.Tasks.Operator.Publish do
  @shortdoc "Publishes Operator's current code as an over-the-air update"
  @moduledoc """
  Releases the current checkout's code to the phone over the air: the
  Core's release path without a cable (docs/DESIGN.md §1):

      mix operator.publish
      mix operator.publish --store /tmp/try_it   # anywhere else (a dry run)

  Compiles (the dev build, which `mix mob.deploy` ships), takes Operator's
  own modules from the compile path (`Mix.Operator.Deliver` says which are
  left out and what needs a native deploy instead), signs the manifest
  with `~/.config/operator/deliver_signing.key` and stores everything in
  `~/.local/share/operator/deliver/`, which `mix operator.deliver.serve`
  serves. Prints what changed since the previous publish.

  The phone fetches it at its next check (at launch, every 5 minutes while
  in front, or Diagnostics → Check for updates now) and runs it from the
  next launch. A launch with it that doesn't get stable rolls it back, and
  the Dyn generation is rebuilt and selftested against it
  (`Operator.Deliver`).

  Publish from the checkout the phone's build came from, or a newer one: a
  manifest with older code than the build on the phone is ignored there.
  A change that needs a new dependency, plugin, migration or native code
  needs `mix mob.deploy --native` first, then a publish.

  Doesn't start the Operator application.
  """
  use Mix.Task

  alias Mix.Operator.Deliver

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [store: :string])

    if Mix.env() != :dev,
      do:
        Mix.raise("Publish the dev build (the one mix mob.deploy ships): run it without MIX_ENV")

    store = opts |> Keyword.get(:store, Deliver.store_root()) |> Path.expand()
    private_key = Deliver.read_private_key!()

    # Compiles, and loads config/config.exs: the app id and channel the
    # phone's build checks for.
    Mix.Task.run("app.config")
    config = Application.get_all_env(:mob_deliver)
    ebin = Mix.Project.compile_path()
    build = Deliver.build(ebin)
    if build == %{}, do: Mix.raise("Nothing to publish in #{ebin}")

    publish_opts = [
      root: store,
      app: Keyword.fetch!(config, :app),
      channel: config |> Keyword.fetch!(:channel) |> to_string(),
      private_key: private_key
    ]

    case Deliver.publish(build, publish_opts) do
      {:ok, report} -> report(report, store)
      {:error, reason} -> Mix.raise("Publish failed: #{inspect(reason)}")
    end
  end

  defp report(%{fields: fields} = report, store) do
    for {what, key} <- report.changed, do: Mix.shell().info("  #{what}  #{key}")
    for key <- report.removed, do: Mix.shell().info("  removed  #{key}")

    since =
      if report.previous_issued_at,
        do: "since the publish of #{report.previous_issued_at}",
        else: "(first publish)"

    Mix.shell().info("""
    Published #{map_size(fields["modules"])} modules for #{fields["app"]} (#{fields["channel"]}) to #{store}
    #{length(report.changed)} added or changed, #{length(report.removed)} removed #{since}; issued_at #{fields["issued_at"]}
    The phone gets it at its next check and runs it from the launch after.\
    """)
  end
end
