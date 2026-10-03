defmodule Operator.App do
  @moduledoc "Application entry point for Operator."

  use Mob.App

  alias Operator.Core.Dyn
  alias Operator.Core.Term

  @impl Mob.App
  def navigation(_platform) do
    stack(:main, root: Operator.ChatScreen)
  end

  @impl Mob.App
  def on_start do
    # Dist first, so a boot step that fails can still be inspected over rpc.
    # No :cookie: the node takes the per-app cookie mob_dev writes to
    # $MOB_BEAMS_DIR/mob_dist_cookie (MobDev.DistCookie on the host side).
    Mob.Dist.ensure_started(node: :"operator_android@127.0.0.1")

    # DNS, CA certs, the agent stack, the repo, the OpenRouter key, the Core
    # and the current Dyn generation (Operator.Boot, timed).
    :ok = Operator.Boot.run()

    Ecto.Migrator.with_repo(Operator.Repo, fn repo ->
      Ecto.Migrator.run(repo, migrations_dir(), :up, all: true)
    end)

    # The terminal theme (dark, monospace `:term` font token) for every screen.
    :ok = Term.install()

    # Safe mode (launches kept failing, no Dyn loaded): the rescue screen.
    # Otherwise chat once signed in; until then the diagnostics screen,
    # which signs in.
    root =
      cond do
        Dyn.safe_mode?() -> Operator.RescueScreen
        Operator.KeyStore.present?() -> Operator.ChatScreen
        true -> Operator.HomeScreen
      end

    Mob.Screen.start_root(root)
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
