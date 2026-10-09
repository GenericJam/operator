defmodule Operator.Core.LibraryGenerationTest do
  # async: false: Dyn compiles into the one code server, and the Keeper is
  # app-named (Operator.Test.Dyn).
  use ExUnit.Case, async: false

  alias Operator.Core.Dyn
  alias Operator.Core.Library
  alias Operator.Test.Dyn, as: T

  @moduletag :tmp_dir
  @moduletag :capture_log

  @scanner """
  defmodule Operator.Dyn.Showcase.Phone.TextScanner do
    def entry do
      %{slug: :text_scanner, name: "Text scanner", category: "Phone", order: 7,
        description: "Read text with the camera.", api: "MobCamera, MobMlkit"}
    end
  end
  """

  setup %{tmp_dir: dir} do
    T.purge_all()
    on_exit(&T.purge_all/0)
    on_exit(fn -> :persistent_term.erase({Library, :catalogue}) end)
    T.start_keeper(Path.join(dir, "dyn"))
    %{dyn: Path.join(dir, "dyn")}
  end

  test "no generation yet: the seed's catalogue" do
    assert Library.catalogue() == Library.seed_catalogue()
  end

  test "a widget the agent added to its library shows; a generation without one drops it" do
    T.activate!(%{"showcase/phone/text_scanner.ex" => @scanner})
    text = Library.catalogue()
    assert text =~ "- text_scanner.ex Text scanner (MobCamera, MobMlkit)\n"
    refute text =~ "audio_recorder.ex"
    assert byte_size(text) <= 6_000

    # Another generation without it: re-read, not the cached text.
    :ok = Dyn.stage_reset()
    :ok = Dyn.stage_delete("showcase/phone/text_scanner.ex")
    :ok = Dyn.stage_put("home.ex", T.screen("Home", "home"))
    assert {:ok, %{n: n}} = Dyn.propose("drop the scanner")
    {:ok, token} = Dyn.request_approval({:activate, n})
    assert {:ok, _} = Dyn.activate(n, token)
    assert Library.catalogue() == Library.seed_catalogue()
  end

  test "reading the generation's sources fails: the seed's catalogue, then the real one once readable",
       %{dyn: dyn} do
    n = T.activate!(%{"showcase/phone/text_scanner.ex" => @scanner})
    [src] = Path.wildcard(Path.join(dyn, "**/#{n}/src"))
    page = Path.join(src, "showcase/phone/text_scanner.ex")
    File.rm!(page)
    # A directory where a source was: reading it raises.
    File.mkdir_p!(page)

    assert Library.catalogue() == Library.seed_catalogue()

    File.rmdir!(page)
    File.write!(page, @scanner)
    assert Library.catalogue() =~ "text_scanner.ex Text scanner"
    assert Dyn.status().generation == n
  end
end
