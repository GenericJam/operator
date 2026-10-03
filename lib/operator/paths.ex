defmodule Operator.Paths do
  @moduledoc "App-private persistent dir: MOB_DATA_DIR on device, _build/host_data on the host."

  @spec data_dir() :: String.t()
  def data_dir do
    dir = System.get_env("MOB_DATA_DIR") || Path.join(File.cwd!(), "_build/host_data")
    File.mkdir_p!(dir)
    dir
  end
end
