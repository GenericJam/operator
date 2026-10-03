defmodule Mix.Tasks.Operator.Handoff do
  @shortdoc "Shows omp's latest /handoff as QR codes for the phone"
  @moduledoc """
  Carries work from omp on the Mac to Operator on the phone:

      mix operator.handoff                     # the newest omp session for this directory
      mix operator.handoff --cwd ~/code/mob    # ... for another directory
      mix operator.handoff path/to/session.jsonl

  Run `/handoff` in omp first: it writes a handoff document into its
  session (a `compaction` entry with `method: "handoff"`). This task takes
  the latest one, prints its title and size, and shows it as QR codes
  (`Operator.Handoff`), one at a time: Enter shows the next, Enter after
  the last one exits. Scan them with the phone's camera or any QR app (they
  open Operator), or with Diagnostics → Scan QR, in any order. Once the last
  one is in, the phone starts a new session that opens with the handoff;
  type what to do next. A handoff over the phone's limit (2,000 lines,
  64 kB) is refused before any code is shown.

  The default session is the newest `*.jsonl` in omp's sessions directory
  for the working directory: `~/.omp/agent/sessions/` (or
  `$PI_CODING_AGENT_DIR/sessions/`), then the directory named as omp names
  it, from the real path with symlinks resolved: one under the home
  directory is `-` plus its path relative to home with `/` as `-`
  (`~/code/operator` → `-code-operator`, home itself `-`), one under the
  temp dir `-tmp-` plus its relative path, anything else `--<absolute path
  with / as ->--`.

  Doesn't start the Operator application.
  """
  use Mix.Task

  alias Mix.Operator.QR
  alias Operator.Handoff

  @impl Mix.Task
  def run(args) do
    handoff = args |> session!() |> handoff!()
    links = Handoff.encode(handoff)
    total = length(links)

    for {link, i} <- Enum.with_index(links, 1) do
      IO.write(IO.ANSI.clear() <> IO.ANSI.home())
      Mix.shell().info(intro(handoff, total))
      QR.print(link, :m)
      next = if i < total, do: "for the next", else: "to finish"
      Mix.shell().prompt("Code #{i} of #{total}. Scan it, then press Enter #{next}.")
    end

    IO.write(IO.ANSI.clear() <> IO.ANSI.home())
  end

  defp session!(args) do
    case OptionParser.parse!(args, strict: [cwd: :string]) do
      {[], [path]} -> path
      {opts, []} -> newest!(Path.expand(opts[:cwd] || File.cwd!()))
      _ -> Mix.raise("Usage: mix operator.handoff [session.jsonl | --cwd <dir>]")
    end
  end

  defp handoff!(path) do
    case read_handoff(path) do
      {:ok, handoff} -> fits!(handoff, path)
      {:error, :no_handoff} -> Mix.raise("No handoff in #{path}: run /handoff in omp first.")
      {:error, reason} -> Mix.raise("Can't read #{path}: #{:file.format_error(reason)}")
    end
  end

  # Refused here, before any QR is drawn, when the phone would refuse it.
  defp fits!(%{summary: summary} = handoff, path) do
    case Handoff.check(handoff) do
      :ok ->
        handoff

      {:error, :too_large} ->
        lines = length(String.split(summary, "\n"))
        kb = :erlang.float_to_binary(byte_size(summary) / 1000, decimals: 1)

        Mix.raise(
          "The handoff in #{path} is #{lines} lines, #{kb} kB. " <> Handoff.message(:too_large)
        )
    end
  end

  defp intro(handoff, total) do
    kb = :erlang.float_to_binary(byte_size(handoff.summary) / 1000, decimals: 1)
    from = if handoff.cwd, do: " from #{handoff.cwd}", else: ""

    """
    Handoff: #{handoff.title || "(untitled)"}
    #{kb} kB#{from}, #{total} QR #{if total == 1, do: "code", else: "codes"}. Scan each with the \
    phone's camera (or Diagnostics → Scan QR), in any order.
    """
  end

  defp newest!(cwd) do
    dir = sessions_dir(cwd)

    case newest_session(dir) do
      {:ok, path} ->
        path

      :error ->
        Mix.raise(
          "No omp session for #{cwd} (looked in #{dir}). Run /handoff in omp there, " <>
            "or pass the session file."
        )
    end
  end

  # ── omp's sessions ──

  @doc false
  # omp's sessions directory for `cwd` (pi-coding-agent's
  # session-paths.ts, getDefaultSessionDirName). `opts`: `:root` (the
  # sessions root), `:home`, `:tmp`.
  @spec sessions_dir(Path.t(), keyword()) :: Path.t()
  def sessions_dir(cwd, opts \\ []) do
    root = Keyword.get_lazy(opts, :root, &sessions_root/0)
    home = realpath(Keyword.get_lazy(opts, :home, &System.user_home!/0))
    tmp = realpath(Keyword.get_lazy(opts, :tmp, &System.tmp_dir!/0))
    cwd = realpath(cwd)

    name =
      cond do
        within?(cwd, home) -> relative_name("-", cwd, home)
        within?(cwd, tmp) -> relative_name("-tmp", cwd, tmp)
        true -> "--" <> encode(String.trim_leading(cwd, "/")) <> "--"
      end

    Path.join(root, name)
  end

  @doc false
  # The most recently written session file in `dir`.
  @spec newest_session(Path.t()) :: {:ok, Path.t()} | :error
  def newest_session(dir) do
    case Path.wildcard(Path.join(dir, "*.jsonl")) do
      [] -> :error
      # Same-second writes: the later name (they start with a timestamp).
      paths -> {:ok, Enum.max_by(paths, &{File.stat!(&1, time: :posix).mtime, &1})}
    end
  end

  @doc false
  # The latest handoff in an omp session file, with the session's title and
  # cwd: `%{title, cwd, summary, created}` for `Operator.Handoff.encode/1`.
  @spec read_handoff(Path.t()) :: {:ok, map()} | {:error, :no_handoff | File.posix()}
  def read_handoff(path) do
    if File.regular?(path) do
      found =
        path
        |> File.stream!()
        |> Enum.reduce(%{slot: nil, changed: nil, header: %{}, handoff: nil}, &scan/2)

      case found do
        %{handoff: nil} ->
          {:error, :no_handoff}

        %{handoff: entry, header: header} ->
          {:ok,
           %{
             title: found.slot || found.changed || header["title"],
             cwd: header["cwd"],
             summary: entry["summary"],
             created: created(entry["timestamp"])
           }}
      end
    else
      {:error, :enoent}
    end
  end

  # Only the lines that can matter are decoded: omp writes compact JSON with
  # `type` first, and message lines can run to megabytes.
  defp scan(line, acc) do
    if String.contains?(line, [~s("type":"session"), ~s("type":"title), ~s("type":"compaction")]) do
      case Jason.decode(line) do
        # The title slot omp keeps current at the top of the file.
        {:ok, %{"type" => "title", "title" => title}} when is_binary(title) ->
          %{acc | slot: title}

        {:ok, %{"type" => "title_change", "title" => title}} when is_binary(title) ->
          %{acc | changed: title}

        {:ok, %{"type" => "session"} = header} ->
          %{acc | header: header}

        {:ok, %{"type" => "compaction", "method" => "handoff", "summary" => s} = entry}
        when is_binary(s) ->
          %{acc | handoff: entry}

        _ ->
          acc
      end
    else
      acc
    end
  end

  defp created(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, at, _offset} -> DateTime.to_unix(at, :millisecond)
      _ -> nil
    end
  end

  defp created(_timestamp), do: nil

  defp sessions_root do
    agent =
      case System.get_env("PI_CODING_AGENT_DIR") do
        dir when dir in [nil, ""] -> Path.join([System.user_home!(), ".omp", "agent"])
        dir -> Path.expand(dir)
      end

    Path.join(agent, "sessions")
  end

  defp within?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp relative_name(prefix, path, root) do
    case encode(String.trim_leading(String.replace_prefix(path, root, ""), "/")) do
      "" -> prefix
      rel -> if String.ends_with?(prefix, "-"), do: prefix <> rel, else: prefix <> "-" <> rel
    end
  end

  defp encode(path), do: String.replace(path, ~r{[/\\:]}, "-")

  # fs.realpathSync: every symlink on the way resolved (macOS's /tmp and
  # /var are links into /private). A path that doesn't exist is kept as
  # given, as omp keeps it.
  defp realpath(path) do
    path = Path.expand(path)

    case resolve(tl(Path.split(path)), "/", 0) do
      {:ok, real} -> real
      :error -> path
    end
  end

  defp resolve(_parts, _at, 40), do: :error
  defp resolve([], at, _links), do: {:ok, at}

  defp resolve([part | rest], at, links) do
    next = Path.join(at, part)

    case File.read_link(next) do
      {:ok, target} -> resolve(tl(Path.split(Path.expand(target, at))) ++ rest, "/", links + 1)
      {:error, :einval} -> resolve(rest, next, links)
      {:error, _missing} -> :error
    end
  end
end
