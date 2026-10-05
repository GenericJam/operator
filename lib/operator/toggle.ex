defmodule Operator.Toggle do
  @moduledoc """
  The front/terminal toggle (PLAN.md "Front and back"). On the front it is
  Operator's logo, the rotary dial, or the symbol the Dyn layer chose
  (`Operator.Core.Front.toggle/0`), in the upper left corner:
  `Operator.ShellScreen` draws it over the front (`overlay/0`) and goes back
  to the terminal on its tap. On the terminal it is the `[frontend]` command
  that starts every top bar (`Operator.TermUI.top_bar/2`), sending the same
  `{:tap, :operator_toggle}`; the screen opens the front with `to_front/1`.
  """

  alias Operator.Core.Front

  @size 44
  @tag :operator_toggle

  @doc "The tap tag the toggle sends its screen."
  @spec tag() :: atom()
  def tag, do: @tag

  # The toggle itself, a #{@size} dp square.
  defp button do
    %{
      type: :box,
      props: %{width: @size, height: @size, on_tap: {self(), @tag}},
      children: [symbol(Front.toggle())]
    }
  end

  @doc "The toggle in the upper left corner of an otherwise empty, see-through layer."
  @spec overlay() :: map()
  def overlay do
    %{
      type: :column,
      props: %{fill_width: true, fill_height: true},
      children: [
        %{type: :spacer, props: %{size: 4}, children: []},
        %{
          type: :row,
          props: %{fill_width: true},
          children: [%{type: :spacer, props: %{size: 4}, children: []}, button()]
        },
        %{type: :spacer, props: %{weight: 1}, children: []}
      ]
    }
  end

  @doc "From a terminal screen to the front (the shell goes on top; its toggle comes back)."
  @spec to_front(Mob.Socket.t()) :: Mob.Socket.t()
  def to_front(socket), do: Mob.Socket.push_screen(socket, Operator.ShellScreen)

  defp symbol(:dial) do
    %{
      type: :image,
      props: %{src: icon_path("dial.png"), width: @size, height: @size, content_mode: :fit},
      children: []
    }
  end

  defp symbol({:text, glyph}) do
    %{
      type: :text,
      props: %{
        text: glyph,
        text_size: 26,
        text_color: :on_surface,
        text_align: :center,
        fill_width: true
      },
      children: []
    }
  end

  # priv/ goes to the device under $MOB_BEAMS_DIR/priv (see Operator.App's
  # migrations_dir/0); on the host it's the app's priv dir.
  defp icon_path(file) do
    base =
      case System.get_env("MOB_BEAMS_DIR") do
        nil -> Application.app_dir(:operator, "priv")
        dir -> Path.join(dir, "priv")
      end

    Path.join([base, "icon", file])
  end
end
