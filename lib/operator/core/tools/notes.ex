defmodule Operator.Core.Tools.Notes do
  @moduledoc "Core tool: append to or read a plain-text notes file in the app's data dir."
  @behaviour Operator.Core.Tool

  @file_name "notes.md"

  @impl true
  def name, do: "notes"

  @impl true
  def description do
    "Keep notes that persist across sessions on this phone. " <>
      "action=append adds `text` as a new line; action=read returns all notes."
  end

  @impl true
  def parameter_schema do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{"type" => "string", "enum" => ["append", "read"]},
        "text" => %{"type" => "string", "description" => "The line to append (action=append)."}
      },
      "required" => ["action"],
      "additionalProperties" => false
    }
  end

  @impl true
  def timeout_ms, do: 5_000

  @impl true
  def run(%{"action" => "append", "text" => text}, ctx) when is_binary(text) and text != "" do
    path = path(ctx)
    File.write!(path, [String.trim_trailing(text), ?\n], [:append])
    {:ok, "Appended. Notes now have #{path |> File.read!() |> line_count()} lines."}
  end

  def run(%{"action" => "append"}, _ctx), do: {:error, "append needs a non-empty `text`"}

  def run(%{"action" => "read"}, ctx) do
    case File.read(path(ctx)) do
      {:ok, ""} -> {:ok, "(no notes yet)"}
      {:ok, body} -> {:ok, body}
      {:error, :enoent} -> {:ok, "(no notes yet)"}
      {:error, reason} -> {:error, "could not read notes: #{:file.format_error(reason)}"}
    end
  end

  def run(args, _ctx),
    do: {:error, "unknown action: #{inspect(args["action"])}; use append or read"}

  @impl true
  def selftest do
    dir =
      Path.join(
        System.tmp_dir!(),
        "operator-notes-selftest-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    ctx = %{data_dir: dir}

    try do
      with {:ok, "(no notes yet)"} <- run(%{"action" => "read"}, ctx),
           {:ok, _} <- run(%{"action" => "append", "text" => "selftest"}, ctx),
           {:ok, "selftest\n"} <- run(%{"action" => "read"}, ctx) do
        :ok
      else
        other -> {:error, other}
      end
    after
      File.rm_rf!(dir)
    end
  end

  defp path(ctx), do: Path.join(ctx.data_dir, @file_name)

  defp line_count(body), do: body |> String.split("\n", trim: true) |> length()
end
