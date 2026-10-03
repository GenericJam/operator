defmodule Operator.Core.Dyn.Selftest do
  @moduledoc """
  Selftests a compiled generation (docs/DESIGN.md §2, step 4), one module
  at a time, each in a fresh process with a `max_heap_size` (killed when
  exceeded, off-heap binaries included), a timeout and `trap_exit` (a
  linked helper that crashes doesn't take the test down unreported).

    * a **tool** (`Operator.Core.Tool`) must name itself (`[a-z][a-z0-9_]*`),
      describe itself, declare a parameter schema and pass its `selftest/0`,
      which a Dyn tool must define;
    * a **screen** (`mount/3` + `render/1`) must mount on a test socket and
      render a view tree (`%{type: atom, children: [...]}` all the way down);
    * any other module just has to have loaded.

  Any module that also exports `selftest/0` gets it run too (`:ok` passes).
  When the test process finishes, processes linked to it go down with it.
  """

  alias Operator.Core.Dyn.Compiler
  alias Operator.Core.Dyn.Generation
  alias Operator.Core.Tool

  @default_timeout_ms 5_000
  @default_max_heap_mb 64

  @doc "The kind a loaded module is filed under."
  @spec kind(module()) :: Generation.kind()
  def kind(mod) do
    cond do
      Tool.tool?(mod) -> :tool
      function_exported?(mod, :mount, 3) and function_exported?(mod, :render, 1) -> :screen
      true -> :module
    end
  end

  @doc """
  Runs every module's test; `{:ok, results}` only if all passed. Options:
  `:selftest_timeout_ms` (#{@default_timeout_ms}), `:selftest_max_heap_mb`
  (#{@default_max_heap_mb}). Each result carries the
  tool's `name` (nil for other kinds).
  """
  @spec run([module()], keyword()) ::
          {:ok, [Generation.selftest()]} | {:error, [Generation.selftest()]}
  def run(mods, opts \\ []) do
    results = mods |> Enum.sort() |> Enum.map(&test(&1, opts))
    if Enum.all?(results, & &1.ok), do: {:ok, results}, else: {:error, results}
  end

  defp test(mod, opts) do
    kind = kind(mod)
    {us, result} = :timer.tc(fn -> isolated(fn -> check(kind, mod) end, opts) end)

    base = %{module: Compiler.logical(mod), kind: kind, ms: div(us, 1000), name: nil}

    case result do
      {:ok, detail, name} -> Map.merge(base, %{ok: true, detail: detail, name: name})
      {:error, detail} -> Map.merge(base, %{ok: false, detail: detail})
    end
  end

  # ── the checks (run inside the test process) ──

  defp check(:tool, mod) do
    name = mod.name()

    with :ok <- tool_name(name),
         :ok <- expect(is_binary(mod.description()), "description/0 must return a string"),
         :ok <- expect(is_map(mod.parameter_schema()), "parameter_schema/0 must return a map"),
         :ok <- expect(function_exported?(mod, :selftest, 0), "a Dyn tool must define selftest/0"),
         :ok <- own_selftest(mod) do
      {:ok, "tool #{name}: selftest passed", name}
    end
  end

  defp check(:screen, mod) do
    socket =
      mod |> Mob.Socket.new() |> Mob.Socket.assign(:size_class, Mob.SizeClass.placeholder())

    with {:ok, %Mob.Socket{} = socket} <- mounted(mod.mount(%{}, %{}, socket)),
         tree = mod.render(socket.assigns),
         :ok <- expect(tree?(tree), "render/1 must return a view tree, got: #{short(tree)}"),
         :ok <- own_selftest(mod) do
      {:ok, "screen: mounted and rendered #{count(tree)} nodes", nil}
    end
  end

  defp check(:module, mod) do
    with :ok <- own_selftest(mod), do: {:ok, "loaded", nil}
  end

  defp tool_name(name) when is_binary(name) do
    expect(
      Regex.match?(~r/\A[a-z][a-z0-9_]{0,63}\z/, name),
      "tool name #{inspect(name)} must match [a-z][a-z0-9_]*"
    )
  end

  defp tool_name(name), do: {:error, "name/0 must return a string, got: #{short(name)}"}

  defp mounted({:ok, %Mob.Socket{}} = ok), do: ok
  defp mounted(other), do: {:error, "mount/3 must return {:ok, socket}, got: #{short(other)}"}

  defp own_selftest(mod) do
    if function_exported?(mod, :selftest, 0) do
      case mod.selftest() do
        :ok -> :ok
        other -> {:error, "selftest/0 returned #{short(other)}"}
      end
    else
      :ok
    end
  end

  defp expect(true, _message), do: :ok
  defp expect(false, message), do: {:error, message}

  defp tree?(%{type: type} = node) when is_atom(type) do
    case Map.get(node, :children, []) do
      kids when is_list(kids) -> Enum.all?(List.flatten(kids), &tree?/1)
      _ -> false
    end
  end

  defp tree?(_other), do: false

  defp count(%{} = node),
    do: 1 + (node |> Map.get(:children, []) |> List.flatten() |> Enum.map(&count/1) |> Enum.sum())

  defp short(term), do: inspect(term, limit: 10, printable_limit: 200)

  # ── the test process ──

  defp isolated(fun, opts) do
    timeout = Keyword.get(opts, :selftest_timeout_ms, @default_timeout_ms)
    heap_mb = Keyword.get(opts, :selftest_max_heap_mb, @default_max_heap_mb)
    parent = self()
    ref = make_ref()

    {pid, mref} =
      spawn_monitor(fn ->
        Process.flag(:trap_exit, true)

        Process.flag(:max_heap_size, %{
          size: div(heap_mb * 1024 * 1024, :erlang.system_info(:wordsize)),
          kill: true,
          error_logger: false,
          include_shared_binaries: true
        })

        result =
          try do
            fun.()
          catch
            kind, reason -> {:error, Exception.format_banner(kind, reason, __STACKTRACE__)}
          end

        send(parent, {ref, result})
        # Linked helpers the module started go down with the test.
        exit(:shutdown)
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(mref, [:flush])
        result

      {:DOWN, ^mref, :process, ^pid, :killed} ->
        {:error, "killed: used more than #{heap_mb} MB of heap"}

      {:DOWN, ^mref, :process, ^pid, reason} ->
        {:error, "exited: " <> Exception.format_exit(reason)}
    after
      timeout ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^mref, :process, ^pid, _} -> :ok
        end

        {:error, "timed out after #{timeout} ms"}
    end
  end
end
