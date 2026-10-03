defmodule Operator.Core.Settings do
  @moduledoc """
  User settings, persisted as `settings.json` in the app's data dir
  (`Operator.Paths.data_dir/0`; a missing or unreadable file means the
  defaults). Each call reads the file, so a change applies at once.

    * `voice`: what `Operator.Core.Voice` reads aloud: `:off`,
      `:important` (default: finished, stopped, error, step limit) or
      `:everything` (also every assistant reply).
  """

  @file_name "settings.json"
  @voices [:off, :important, :everything]

  @type voice :: :off | :important | :everything

  @spec voices() :: [voice()]
  def voices, do: @voices

  @spec voice(String.t()) :: voice()
  def voice(dir \\ Operator.Paths.data_dir()) do
    case read(dir) do
      %{"voice" => v} when v in ["off", "important", "everything"] -> String.to_existing_atom(v)
      _ -> :important
    end
  end

  @spec put_voice(voice(), String.t()) :: :ok
  def put_voice(voice, dir \\ Operator.Paths.data_dir()) when voice in @voices,
    do: write(dir, Map.put(read(dir), "voice", Atom.to_string(voice)))

  defp read(dir) do
    with {:ok, json} <- File.read(Path.join(dir, @file_name)),
         {:ok, %{} = map} <- Jason.decode(json) do
      map
    else
      _ -> %{}
    end
  end

  # Written to a temp file and renamed, so a crash mid-write leaves the old file.
  defp write(dir, map) do
    path = Path.join(dir, @file_name)
    tmp = path <> ".tmp"
    File.write!(tmp, Jason.encode!(map, pretty: true))
    File.rename!(tmp, path)
  end
end
