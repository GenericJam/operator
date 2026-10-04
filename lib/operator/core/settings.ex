defmodule Operator.Core.Settings do
  @moduledoc """
  User settings, persisted as `settings.json` in the app's data dir
  (`Operator.Paths.data_dir/0`; a missing or unreadable file means the
  defaults). Each call reads the file, so a change applies at once.

    * `voice`: what `Operator.Core.Voice` reads aloud: `:off`,
      `:important` (default: finished, stopped, error, step limit) or
      `:everything` (also every assistant reply).
    * `daily_cap`: dollars of model calls a day before the loop refuses
      the next one (`Operator.Core.Budget`); default #{1.0}.
    * `deliver_endpoint`: the Mac's update server, where mob_deliver
      fetches Operator's code updates (`Operator.Deliver`); none by
      default. Set by scanning `mix operator.deliver.qr`.
    * `front_stack`: the front screens open when the app last ran
      (`Operator.Core.Front`), the top one first, by their Dyn names
      (`"Showcase.GalleryScreen"`); none by default.
  """

  @file_name "settings.json"
  @voices [:off, :important, :everything]
  @default_daily_cap 1.0

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

  @spec daily_cap(String.t()) :: float()
  def daily_cap(dir \\ Operator.Paths.data_dir()) do
    case read(dir) do
      %{"daily_cap" => cap} when is_number(cap) and cap >= 0 -> cap * 1.0
      _ -> @default_daily_cap
    end
  end

  @spec put_daily_cap(number(), String.t()) :: :ok
  def put_daily_cap(cap, dir \\ Operator.Paths.data_dir()) when is_number(cap) and cap >= 0,
    do: write(dir, Map.put(read(dir), "daily_cap", cap * 1.0))

  @spec deliver_endpoint(String.t()) :: String.t() | nil
  def deliver_endpoint(dir \\ Operator.Paths.data_dir()) do
    case read(dir) do
      %{"deliver_endpoint" => endpoint} when is_binary(endpoint) and endpoint != "" -> endpoint
      _ -> nil
    end
  end

  @spec put_deliver_endpoint(String.t(), String.t()) :: :ok
  def put_deliver_endpoint(endpoint, dir \\ Operator.Paths.data_dir()) when is_binary(endpoint),
    do: write(dir, Map.put(read(dir), "deliver_endpoint", endpoint))

  @spec front_stack(String.t()) :: [String.t()]
  def front_stack(dir \\ Operator.Paths.data_dir()) do
    case read(dir) do
      %{"front_stack" => names} when is_list(names) -> Enum.filter(names, &is_binary/1)
      _ -> []
    end
  end

  @spec put_front_stack([String.t()], String.t()) :: :ok
  def put_front_stack(names, dir \\ Operator.Paths.data_dir()) when is_list(names),
    do: write(dir, Map.put(read(dir), "front_stack", names))

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
