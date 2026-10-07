defmodule Operator.Core.LibraryTest do
  use ExUnit.Case, async: true

  alias Operator.Core.Dyn.Seed
  alias Operator.Core.Library

  @phone """
  defmodule Operator.Dyn.Showcase.Phone.AudioRecorder do
    use Mob.Screen

    def entry do
      %{
        slug: :audio_recorder,
        name: "Audio recorder",
        category: "Phone",
        order: 1,
        description: "Record and play back a memo.",
        api: "Mob.Audio, Mob.Permissions"
      }
    end
  end
  """

  @bare """
  defmodule Operator.Dyn.Showcase.Components.Bare do
    use Mob.Screen

    def entry, do: %{slug: :bare, name: "Bare", category: "Forms", order: 9, description: "x"}
  end
  """

  defp long_example(slug, tag) do
    attrs = Enum.map_join(1..30, " ", &"attr_#{&1}={@value_#{&1}}")

    """
    defmodule Operator.Dyn.Showcase.Components.Long do
      alias MobMishka.Components.#{tag}

      def entry, do: %{slug: :#{slug}, name: "Long", category: "Forms", order: 1, description: "x"}

      def examples do
        [
          %Example{
            title: "All of it",
            code: ~S\"\"\"
            # The opening tag runs over lines.
            <#{tag}
              #{attrs}
            />
            \"\"\"
          }
        ]
      end

      def props, do: [%{name: "attr_1"}, %{name: "extra"}, %{name: "snap/2", type: "helper"}]
    end
    """
  end

  defp line_for(catalogue, path) do
    file = Path.basename(path)
    Enum.filter(String.split(catalogue, "\n"), &String.starts_with?(&1, "- #{file} "))
  end

  test "every component page of the seed has one line, by its path" do
    pages = for {"showcase/components/" <> _ = path, _} <- Seed.sources(), do: path
    assert pages != []
    components = for %{kind: :component, path: path} <- Library.entries(), do: path
    assert Enum.sort(components) == Enum.sort(pages)

    for path <- pages do
      assert [_] = line_for(Library.catalogue(), path), path
    end

    slider = Enum.find(Library.entries(), &(&1.path == "showcase/components/slider.ex"))
    assert %{tag: "MishkaSlider", category: "Forms"} = slider
    assert "on_change" in slider.props
    refute "snap/2" in slider.props
    assert slider.usage =~ ~r/^<MishkaSlider .*\/>$/
  end

  test "the complete seed catalogue fits its request budget" do
    assert byte_size(Library.catalogue()) <= 6_000
  end

  test "a phone page's line names the APIs it uses" do
    text = Library.build(%{"showcase/phone/audio_recorder.ex" => @phone})
    assert [line] = line_for(text, "showcase/phone/audio_recorder.ex")
    assert line =~ "Audio recorder"
    assert line =~ "Mob.Audio, Mob.Permissions"

    assert [%{api: "Mob.Audio, Mob.Permissions", kind: :phone}] =
             Library.parse(%{"showcase/phone/audio_recorder.ex" => @phone})
  end

  test "a page without examples, props or a Mishka alias still gets a line" do
    sources = %{"showcase/components/bare.ex" => @bare}
    assert [%{name: "Bare", tag: nil, usage: nil, props: []}] = Library.parse(sources)
    assert [line] = line_for(Library.build(sources), "showcase/components/bare.ex")
    assert line =~ "Bare"
  end

  test "files outside the library, and pages that don't parse, are left out" do
    sources = %{
      "showcase/page.ex" => @bare,
      "showcase/components/nested/x.ex" => @bare,
      "showcase/components/broken.ex" => "defmodule Oops do",
      "showcase/components/bare.ex" => @bare
    }

    assert [%{path: "showcase/components/bare.ex"}] = Library.parse(sources)
  end

  test "a long opening tag is cut at an attribute, under the cap" do
    sources = %{"showcase/components/long.ex" => long_example("long", "MishkaLong")}
    assert [%{tag: "MishkaLong", usage: usage}] = Library.parse(sources)
    # The whole tag on one line.
    assert usage =~ ~r/^<MishkaLong attr_1=\{@value_1\} .* attr_30=\{@value_30\} \/>$/

    assert [line] = line_for(Library.build(sources), "showcase/components/long.ex")
    assert [_, shown] = Regex.run(~r/^- long\.ex (<MishkaLong .*? … \/>)/, line)
    assert String.length(shown) <= Library.usage_cap()
    # Props the usage shows aren't listed again; helpers never are.
    assert line =~ ~r/ \+extra$/
  end

  test "no usage line in the seed's catalogue is over the cap" do
    for line <- String.split(Library.catalogue(), "\n"), String.starts_with?(line, "- ") do
      [_, usage] = Regex.run(~r/^- \S+ (.*?)(?: \+[a-z0-9_? ]+)?$/, line)
      assert String.length(usage) <= Library.usage_cap(), line
    end
  end
end
