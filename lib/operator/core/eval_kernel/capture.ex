defmodule Operator.Core.EvalKernel.Capture do
  @moduledoc """
  The group leader an `eval` runs under: it takes what the evaluated code
  prints and keeps the first `max` bytes, counting the rest, so a print in
  a loop can't fill the phone's memory before the timeout. A plain
  `StringIO` would keep everything.

  It speaks the Erlang I/O protocol for output only; a read gets `:eof`,
  so `IO.gets/1` returns at once instead of waiting for a keyboard the
  phone doesn't have.
  """
  use GenServer

  @spec start_link(pos_integer()) :: GenServer.on_start()
  def start_link(max), do: GenServer.start_link(__MODULE__, max)

  @doc "What was printed (at most `max` bytes) and how many bytes in all."
  @spec contents(pid()) :: {binary(), non_neg_integer()}
  def contents(pid), do: GenServer.call(pid, :contents)

  @impl true
  def init(max), do: {:ok, %{max: max, kept: [], kept_bytes: 0, total: 0}}

  @impl true
  def handle_call(:contents, _from, s),
    do: {:reply, {s.kept |> Enum.reverse() |> IO.iodata_to_binary(), s.total}, s}

  @impl true
  def handle_info({:io_request, from, reply_as, request}, s) do
    {reply, s} = request(request, s)
    send(from, {:io_reply, reply_as, reply})
    {:noreply, s}
  end

  def handle_info(_other, s), do: {:noreply, s}

  defp request({:put_chars, chars}, s), do: put(chars, s)
  defp request({:put_chars, _encoding, chars}, s), do: put(chars, s)

  defp request({:put_chars, mod, fun, args}, s),
    do: request({:put_chars, :unicode, mod, fun, args}, s)

  defp request({:put_chars, _encoding, mod, fun, args}, s) do
    put(apply(mod, fun, args), s)
  rescue
    _ -> {{:error, :put_chars}, s}
  end

  defp request({:requests, requests}, s) do
    Enum.reduce_while(requests, {:ok, s}, fn r, {_, s} ->
      case request(r, s) do
        {:ok, s} -> {:cont, {:ok, s}}
        {error, s} -> {:halt, {error, s}}
      end
    end)
  end

  defp request(:getopts, s), do: {[binary: true, encoding: :unicode], s}
  defp request({:setopts, _}, s), do: {:ok, s}
  defp request({:get_geometry, _}, s), do: {{:error, :enotsup}, s}

  defp request(r, s)
       when is_tuple(r) and elem(r, 0) in [:get_chars, :get_line, :get_until, :get_password],
       do: {:eof, s}

  defp request(_other, s), do: {{:error, :request}, s}

  defp put(chars, s) do
    bin = :unicode.characters_to_binary(chars)
    bin = if is_binary(bin), do: bin, else: IO.iodata_to_binary(chars)
    room = s.max - s.kept_bytes
    take = min(room, byte_size(bin))

    s =
      if take > 0,
        do: %{s | kept: [binary_part(bin, 0, take) | s.kept], kept_bytes: s.kept_bytes + take},
        else: s

    {:ok, %{s | total: s.total + byte_size(bin)}}
  rescue
    _ -> {{:error, :put_chars}, s}
  end
end
