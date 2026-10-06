defmodule Operator.Core.FilesTest do
  # Sets the app env `:app_temp`, read VM-wide.
  use ExUnit.Case, async: false

  alias Operator.Core.Files

  @moduletag :tmp_dir

  # The app's temporary files (Android's cacheDir, where the picker, the
  # camera and the recorder leave their output) and the rest of the data dir,
  # which Dyn code must not reach through it.
  setup %{tmp_dir: dir} do
    cache = Path.join(dir, "cache")
    File.mkdir_p!(cache)
    Application.put_env(:operator, :app_temp, cache)
    on_exit(fn -> Application.delete_env(:operator, :app_temp) end)
    %{cache: cache, data: Operator.Paths.data_dir()}
  end

  describe "keep/2" do
    test "copies a capability's output into the workspace's inbox, under the given name",
         %{cache: cache} do
      src = Path.join(cache, "mob_file_17_0_notes.txt")
      File.write!(src, "one\ntwo\n")
      File.mkdir_p!(Path.join(cache, "mob_temp"))
      nested = Path.join(cache, "mob_temp/clip.m4a")
      File.write!(nested, "audio")

      assert {:ok, kept} = Files.keep(src, "notes.txt")
      assert {:ok, again} = Files.keep(src, "notes.txt")
      assert {:ok, clip} = Files.keep(nested)
      on_exit(fn -> Enum.each([kept, again, clip], &File.rm/1) end)

      assert Path.basename(Path.dirname(kept)) == "inbox"
      assert Path.basename(kept) =~ ~r/\Anotes(-\d+)?\.txt\z/
      assert again != kept
      assert Path.basename(clip) =~ ~r/\Aclip(-\d+)?\.m4a\z/
      assert Files.read(kept) == {:ok, "one\ntwo\n"}
      # A copy: the screen can still show the original.
      assert File.read!(src) == "one\ntwo\n"
    end

    test "refuses the app's private files, .., symlinks out and directories",
         %{cache: cache, data: data, tmp_dir: dir} do
      session = Path.join(data, "sessions/s1.json")
      File.mkdir_p!(Path.dirname(session))
      File.write!(session, "secret")
      on_exit(fn -> File.rm(session) end)

      File.ln_s!(session, Path.join(cache, "mob_file_1_0_link"))
      File.ln_s!(Path.dirname(session), Path.join(cache, "dirlink"))
      File.mkdir_p!(Path.join(cache, "mob_file_2_0_dir"))
      File.write!(Path.join(dir, "outside.txt"), "x")
      # A real temporary file, but named through `..`.
      File.write!(Path.join(cache, "mob_file_9_0_x"), "x")

      for path <- [
            session,
            cache,
            Path.join(cache, "mob_file_1_0_link"),
            Path.join(cache, "dirlink/s1.json"),
            Path.join(cache, "mob_file_2_0_dir"),
            Path.join(cache, "../outside.txt"),
            Path.join([cache, "..", "cache", "mob_file_9_0_x"])
          ] do
        assert {:error, message} = Files.keep(path), path
        assert message =~ "isn't in the app's temporary files"
      end

      assert File.read!(session) == "secret"
    end

    test "off the phone (the host) nothing is kept", %{cache: cache} do
      Application.delete_env(:operator, :app_temp)
      src = Path.join(cache, "a.txt")
      File.write!(src, "a")
      assert {:error, "There are no temporary files here" <> _} = Files.keep(src)
    end
  end
end
