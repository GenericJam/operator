defmodule Operator.TzData do
  @moduledoc """
  Gives `:time_zone_info` (pulled in by jido's scheduler) its data file.

  Its default persistence reads `:code.priv_dir(:time_zone_info)`, which is
  `{:error, :bad_name}` on device (mob_dev ships deps' ebins, not their
  priv/), so `TimeZoneInfo.Worker` crashes and takes `ensure_all_started(:jido)`
  down with it. The 370 KB data file is embedded here at compile time,
  written to the cache dir, and handed over through the FileSystem
  persistence (config/config.exs selects it; the path is set here, before
  the app starts).
  """

  @data_path Path.expand(Path.join([__DIR__, "../..", "deps/time_zone_info/priv/data.etf"]))
  @external_resource @data_path
  @data File.read!(@data_path)

  @spec install!() :: :ok
  def install! do
    path = Path.join(Mob.Storage.dir(:cache), "time_zone_info.etf")
    File.write!(path, @data)
    Application.put_env(:time_zone_info, :file_system, path: path)
  end
end
