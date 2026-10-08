defmodule Mix.Operator.QR do
  @moduledoc """
  Draws a QR code in the terminal for the `mix operator.*` tasks.

  Black modules on white, whatever the terminal's colours: two rows per
  line with the upper half-block, foreground the top row and background the
  bottom one (256-colour 16 and 231 aren't remapped by themes), inside the
  4-module quiet zone the spec asks for (EQRCode's own is 2). EQRCode comes
  with mob_dev, a :dev-only dependency; elsewhere the text is printed
  instead.
  """

  @compile {:no_warn_undefined, EQRCode}

  @doc "Prints `text` as a QR code at error correction level `ecc` (`:l`, `:m`, `:q`, `:h`)."
  @spec print(String.t(), :l | :m | :q | :h) :: :ok
  def print(text, ecc \\ :l) do
    if Mix.env() != :test and Code.ensure_loaded?(EQRCode) do
      rows =
        EQRCode.encode(text, ecc).matrix
        |> Tuple.to_list()
        |> Enum.map(&([0, 0] ++ Tuple.to_list(&1) ++ [0, 0]))

      width = length(hd(rows))
      blank = List.duplicate(0, width)
      warn_if_narrow(width)

      ([blank, blank] ++ rows ++ [blank, blank])
      |> Enum.chunk_every(2, 2, [blank])
      |> Enum.each(fn [top, bottom] -> IO.puts(line(top, bottom)) end)
    else
      Mix.shell().info("(No QR renderer outside :dev; run with MIX_ENV=dev.) Code:\n#{text}")
    end
  end

  # A row that wraps can't be scanned.
  defp warn_if_narrow(width) do
    case :io.columns() do
      {:ok, columns} when columns < width ->
        Mix.shell().info(
          "The terminal is #{columns} columns wide and this code needs #{width}: widen it (or zoom out)."
        )

      _ ->
        :ok
    end
  end

  defp line(top, bottom) do
    cells = Enum.zip_with(top, bottom, &"\e[38;5;#{colour(&1)};48;5;#{colour(&2)}m▀")
    [cells, IO.ANSI.reset()]
  end

  defp colour(1), do: 16
  defp colour(_light), do: 231
end
