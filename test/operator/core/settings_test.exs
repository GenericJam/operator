defmodule Operator.Core.SettingsTest do
  use ExUnit.Case, async: true

  alias Operator.Core.Settings

  @moduletag :tmp_dir

  test "voice defaults to :important and persists what is put", %{tmp_dir: dir} do
    assert Settings.voice(dir) == :important

    for v <- [:off, :everything, :important] do
      :ok = Settings.put_voice(v, dir)
      assert Settings.voice(dir) == v
    end
  end

  test "other keys in the file are kept", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "settings.json"), ~s({"theme": "dark"}))
    :ok = Settings.put_voice(:off, dir)

    assert Jason.decode!(File.read!(Path.join(dir, "settings.json"))) ==
             %{"theme" => "dark", "voice" => "off"}
  end

  test "an unreadable file or unknown value means the default", %{tmp_dir: dir} do
    path = Path.join(dir, "settings.json")
    File.write!(path, "{not json")
    assert Settings.voice(dir) == :important
    File.write!(path, ~s({"voice": "loud"}))
    assert Settings.voice(dir) == :important
  end
end
