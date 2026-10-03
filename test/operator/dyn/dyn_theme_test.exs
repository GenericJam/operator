defmodule Operator.Core.DynThemeTest do
  # The theme is VM-wide (persistent_term), and so are Dyn generations.
  use ExUnit.Case, async: false

  import Operator.Test.Dyn

  alias Operator.Core.DynTheme
  alias Operator.Core.Term

  @moduletag :tmp_dir
  @moduletag :capture_log

  setup do
    purge_all()

    on_exit(fn ->
      purge_all()
      :persistent_term.erase({Term, :theme})
    end)
  end

  defp theme_source(body) do
    """
    defmodule Operator.Dyn.Theme do
      def overrides, do: #{body}
    end
    """
  end

  test "validate keeps known keys in range and names the first bad one" do
    assert {:ok, %{palette: %{"bg" => 0xFF000000}, text_size: 15, line_height: 1.5}} =
             DynTheme.validate(%{
               "palette" => %{bg: 0xFF000000},
               text_size: 15,
               line_height: 1.5
             })

    assert {:error, "unknown palette colour \"sky\""} =
             DynTheme.validate(%{palette: %{"sky" => 1}})

    assert {:error, "fg must be 0xAARRGGBB"} = DynTheme.validate(%{palette: %{"fg" => -1}})
    assert {:error, "text_size must be an integer 10..24"} = DynTheme.validate(%{text_size: 99})
    assert {:error, "unknown theme key :fonts"} = DynTheme.validate(%{fonts: %{}})
    assert {:error, "overrides/0 must return a map" <> _} = DynTheme.validate([:bg])
  end

  test "an activated generation's theme is drawn; a revert or a broken one brings back the default",
       %{tmp_dir: dir} do
    start_keeper(dir)
    theme = start_supervised!({DynTheme, name: nil})
    :ok = DynTheme.subscribe(theme)
    default_bg = Term.default_theme().palette["bg"]

    activate!(%{"theme.ex" => theme_source(~s(%{palette: %{"bg" => 0xFF102030}, text_size: 16}))})
    assert_receive {:operator_theme, :changed}
    assert Term.theme().palette["bg"] == 0xFF102030
    assert Term.theme().text_size == 16
    assert {:ok, Operator.Dyn.G1.Theme} = DynTheme.status(theme)

    # a theme that raises: not applied, the default draws, the reason is kept
    activate!(%{"theme.ex" => theme_source(~s(raise "boom"))})
    assert_receive {:operator_theme, :changed}
    assert Term.theme().palette["bg"] == default_bg
    assert {:error, "overrides/0 crashed:" <> _} = DynTheme.status(theme)

    # a valid one with a bad value: refused whole
    activate!(%{"theme.ex" => theme_source(~s(%{palette: %{"bg" => 1}, text_size: 3}))})
    assert_receive {:operator_theme, :changed}
    assert Term.theme().text_size == Term.default_theme().text_size
    assert {:error, "text_size must be an integer 10..24"} = DynTheme.status(theme)
  end
end
