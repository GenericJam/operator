defmodule Operator.Core.DynScreens do
  @moduledoc """
  Dyn screens in Operator (`config :rho, :dyn, screens: ...`): mob's
  (`Rho.Dyn.Screens.Mob`), shown in the front (`Operator.Core.Front`),
  which says when an approved generation is on screen (`live/1`).
  """
  @behaviour Rho.Dyn.Screens

  alias Operator.Core.Front
  alias Rho.Dyn.Screens.Mob, as: MobScreens

  @impl true
  defdelegate screen_source?(forms), to: MobScreens

  @impl true
  defdelegate entry(), to: MobScreens

  @impl true
  defdelegate screen?(module), to: MobScreens

  @impl true
  defdelegate selftest(module), to: MobScreens

  @impl true
  defdelegate after_first_render(mfa), to: MobScreens

  @impl true
  defdelegate subscribe_app_events(), to: MobScreens

  @impl true
  defdelegate left_app?(message), to: MobScreens

  @impl true
  defdelegate guide(), to: MobScreens

  @doc """
  Generation `n` (current) is live once the front runs it and shows
  something; its empty note means it is still starting. Exits when no
  front runs (the caller then takes the activation as enough).
  """
  @impl true
  def live(n) do
    case Front.status() do
      %{generation: ^n, view: {:note, ""}} -> :waiting
      %{generation: ^n} -> :live
      _ -> :waiting
    end
  end
end
