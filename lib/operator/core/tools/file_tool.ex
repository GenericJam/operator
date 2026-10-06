defmodule Operator.Core.Tools.FileTool do
  @moduledoc """
  What the `file_*` tools share: a path checked against
  `Operator.Core.Files`' roots and, for Android's shared storage, the
  user's All files access, asked through the chat screen
  (`Operator.Core.Phone`, action `:permission`) the first time.
  `ctx[:shared_access]` (`:granted` or an error text) stands in for the
  answer in tests.
  """

  alias Operator.Core.Files
  alias Operator.Core.Tools.PhoneTool

  @spec resolve(term(), :read | :write, map()) ::
          {:ok, Path.t(), Files.root()} | {:error, String.t()}
  def resolve(path, mode, ctx) do
    with {:ok, abs, root} <- Files.resolve(path, mode, ctx),
         :ok <- access(root, ctx) do
      {:ok, abs, root}
    end
  end

  defp access(root, ctx) do
    if Files.needs_access?(root) do
      answer =
        case Map.fetch(ctx, :shared_access) do
          {:ok, :granted} -> {:ok, :granted}
          {:ok, error} -> {:error, error}
          :error -> PhoneTool.call(:permission, %{capability: :all_files}, ctx, 175_000)
        end

      case answer do
        {:ok, :granted} -> :ok
        {:error, _} = error -> error
      end
    else
      :ok
    end
  end

  @doc "The roots, one line each, for the model."
  @spec roots_text(map()) :: String.t()
  def roots_text(ctx) do
    Enum.map_join(Files.roots(ctx), "\n", fn r ->
      ro = if r.access == :read, do: " (read-only)", else: ""
      "#{r.name}: #{r.path}#{ro} — #{r.about}"
    end)
  end

  @doc "Byte count, readable."
  @spec size(non_neg_integer()) :: String.t()
  def size(n) when n < 1024, do: "#{n} B"
  def size(n) when n < 1024 * 1024, do: "#{Float.round(n / 1024, 1)} KB"
  def size(n) when n < 1024 * 1024 * 1024, do: "#{Float.round(n / 1024 / 1024, 1)} MB"
  def size(n), do: "#{Float.round(n / 1024 / 1024 / 1024, 2)} GB"

  @doc "A posix error, readable."
  @spec posix(atom(), String.t()) :: String.t()
  def posix(:enoent, path), do: "#{path} doesn't exist."
  def posix(:eacces, path), do: "No permission for #{path}."
  def posix(:eisdir, path), do: "#{path} is a directory."
  def posix(:enotdir, path), do: "#{path} isn't a directory."
  def posix(:eexist, path), do: "#{path} already exists."
  def posix(:enospc, _path), do: "The phone's storage is full."
  def posix(reason, path), do: "#{path}: #{:file.format_error(reason)}"
end
