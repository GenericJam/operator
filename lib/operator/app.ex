defmodule Operator.App do
  @moduledoc "Application entry point for Operator."

  use Mob.App

  alias Operator.Core.Dyn
  alias Operator.Core.Dyn.Seed
  alias Operator.Core.Front
  alias Operator.Core.Term

  @impl Mob.App
  def navigation(_platform) do
    stack(:main, root: Operator.ChatScreen)
  end

  @impl Mob.App
  def on_start do
    # Dist first, so a boot step that fails can still be inspected over rpc.
    # Operator.Cluster starts it in the saved mode, after Mob.Dist's delay:
    # the cluster (TLS on the Wi-Fi address) when it is on, otherwise the
    # development link (Mob.Dist, loopback only; no :cookie: the node takes
    # the per-app cookie mob_dev writes to $MOB_BEAMS_DIR/mob_dist_cookie).
    # Operator.Cluster.Remote answers the other members' agents through the
    # Bus (the cluster's :pg scope, which Operator.Cluster owns): restarted
    # with it, so it re-joins a new scope.
    {:ok, _} =
      Supervisor.start_link(
        [{Operator.Cluster, dev_node: :"operator_android@127.0.0.1"}, Operator.Cluster.Remote],
        strategy: :rest_for_one,
        name: Operator.Cluster.Supervisor
      )

    # DNS, CA certs, the agent stack, the repo, the provider sign-ins, the
    # Core and the current Dyn generation (Operator.Boot, timed).
    :ok = Operator.Boot.run()

    Ecto.Migrator.with_repo(Operator.Repo, fn repo ->
      Ecto.Migrator.run(repo, migrations_dir(), :up, all: true)
    end)

    # The terminal theme (dark, monospace `:term` font token) for every screen.
    :ok = Term.install()

    # The terminal: safe mode's rescue screen (launches kept failing, no Dyn
    # loaded); otherwise the chat (signed out, it says to sign in from the
    # menu).
    root = if Dyn.safe_mode?(), do: Operator.RescueScreen, else: Operator.ChatScreen

    {:ok, _} = Mob.Screen.start_root(root)

    # The default front (the seed) is installed in the background on the
    # first launch (Operator.Core.Dyn.Seed); the front says so meanwhile.
    _ = Seed.start()

    # The app opens on the front (the shell over the terminal; the toggle
    # pops it), except in safe mode, where there is no front to show.
    unless Dyn.safe_mode?(), do: Front.navigate({:push, Operator.ShellScreen, %{}})
    :ok
  end

  # Returns the path to the migrations directory for the current environment.
  #
  # WHY NOT Application.app_dir/2?
  #
  # Application.app_dir(app, "priv/repo/migrations") calls :code.priv_dir(app)
  # under the hood. That works in a normal `mix run` dev environment where the
  # app lives in $OTP_ROOT/lib/APP-VERSION/ebin/.
  #
  # On Android and iOS, Mob deploys .beam files to a flat -pa directory with no
  # versioned lib structure, so :code.priv_dir/1 returns {error, bad_name}.
  # Ecto.Migrator.run/3 silently finds zero migrations and logs "Migrations
  # already up" — tables are never created and any query against them crashes
  # the screen GenServer, making the screen appear frozen.
  #
  # The fix: mob_beam.c/mob_beam.m set MOB_BEAMS_DIR=beams_dir before erl_start.
  # The deployer pushes priv/ into beams_dir/priv/ and runs chmod -R 755 on it
  # (mkdir-as-root creates system:system drwxrwx--x dirs that the app process
  # can traverse but not list, breaking Path.wildcard). Here we read MOB_BEAMS_DIR
  # and pass the explicit path to Ecto.Migrator.run/4.
  defp migrations_dir do
    case System.get_env("MOB_BEAMS_DIR") do
      nil -> Application.app_dir(:operator, "priv/repo/migrations")
      beams_dir -> Path.join([beams_dir, "priv", "repo", "migrations"])
    end
  end
end
