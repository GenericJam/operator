defmodule Operator.Dyn.Showcase.Phone.TfliteClassify.Jpeg do
  @moduledoc """
  A small baseline JPEG decoder, for feeding photos to a model: the
  phone's plugins hand photos over as JPEG files, and a model wants pixels.

  `decode/1` takes the file's bytes and answers `{:ok, %{width:, height:,
  rgb:}}`, `rgb` an `Nx` tensor `{height, width, 3}` of `:f32` in 0..255.
  It reads what phones write (Android's `Bitmap.compress`, iOS ImageIO):
  baseline Huffman (SOF0/SOF1), 8 bits, grey or YCbCr, any chroma
  subsampling, restart markers. Anything else is `{:error, reason}`:
  progressive, arithmetic or lossless JPEGs, CMYK, multi-scan files.

  The entropy decoding is plain Elixir (Huffman codes read bit by bit off a
  bitstring); the inverse DCT, upsampling and colour conversion are `Nx`
  over all the blocks at once. Meant for small images (a thumbnail of a
  few hundred pixels): the bit-by-bit part is slow on big ones.
  """

  # The natural (row-major) position of the k-th coefficient in zigzag order.
  @zigzag [0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48] ++
            [41, 34, 27, 20, 13, 6, 7, 14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22] ++
            [15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55] ++
            [62, 63]
  # Its inverse: for each natural position, where it is in zigzag order.
  @natural @zigzag |> Enum.with_index() |> Enum.sort() |> Enum.map(&elem(&1, 1))

  # The 8-point inverse DCT basis: m[u][x] = c(u)/2 * cos((2x + 1)uπ/16).
  @idct for u <- 0..7,
            do:
              for(
                x <- 0..7,
                do:
                  if(u == 0, do: :math.sqrt(0.5), else: 1.0) / 2 *
                    :math.cos((2 * x + 1) * u * :math.pi() / 16)
              )

  @doc "Decodes a baseline JPEG's bytes into an RGB tensor."
  @spec decode(binary()) ::
          {:ok, %{width: pos_integer(), height: pos_integer(), rgb: Nx.Tensor.t()}}
          | {:error, String.t()}
  def decode(<<0xFF, 0xD8, rest::binary>>) do
    segments(rest, %{q: %{}, huff: %{}, ri: 0, frame: nil})
  rescue
    # Truncated or corrupt data shows up as a failed match somewhere below.
    _ in [MatchError, FunctionClauseError, CaseClauseError, ArgumentError] ->
      {:error, "the JPEG is damaged or uses something this decoder doesn't read"}
  end

  def decode(_bytes), do: {:error, "not a JPEG"}

  # ── markers ──

  # Fill bytes before a marker.
  defp segments(<<0xFF, 0xFF, rest::binary>>, s), do: segments(<<0xFF, rest::binary>>, s)

  defp segments(<<0xFF, marker, len::16, rest::binary>>, s) do
    body_len = len - 2
    <<body::binary-size(^body_len), rest::binary>> = rest

    case marker do
      0xDB ->
        segments(rest, %{s | q: quant_tables(body, s.q)})

      0xC4 ->
        segments(rest, %{s | huff: huffman_tables(body, s.huff)})

      0xDD ->
        segments(rest, %{s | ri: :binary.decode_unsigned(body)})

      m when m in [0xC0, 0xC1] ->
        with {:ok, f} <- frame(body), do: segments(rest, %{s | frame: f})

      m when m in [0xC2, 0xC6, 0xCA, 0xCE] ->
        {:error, "progressive JPEG not supported"}

      m when m in [0xC3, 0xC5, 0xC7, 0xC9, 0xCB, 0xCD, 0xCF] ->
        {:error, "not a baseline JPEG"}

      0xDA ->
        scan(body, rest, s)

      # APPn, comments and the rest: skipped.
      _ ->
        segments(rest, s)
    end
  end

  defp segments(_bytes, _s), do: {:error, "no image data"}

  # Quantization tables, kept in zigzag order (as stored), 8- or 16-bit.
  defp quant_tables(<<>>, q), do: q

  defp quant_tables(<<0::4, id::4, t::binary-size(64), rest::binary>>, q),
    do: quant_tables(rest, Map.put(q, id, :binary.bin_to_list(t)))

  defp quant_tables(<<1::4, id::4, t::binary-size(128), rest::binary>>, q),
    do: quant_tables(rest, Map.put(q, id, for(<<v::16 <- t>>, do: v)))

  # Huffman tables as %{{length, code} => symbol}, keyed {class, id}
  # (class 0: DC, 1: AC).
  defp huffman_tables(<<>>, huff), do: huff

  defp huffman_tables(<<class::4, id::4, counts::binary-size(16), rest::binary>>, huff) do
    counts = :binary.bin_to_list(counts)
    total = Enum.sum(counts)
    <<symbols::binary-size(^total), rest::binary>> = rest
    huffman_tables(rest, Map.put(huff, {class, id}, codes(counts, :binary.bin_to_list(symbols))))
  end

  # Canonical codes: consecutive within a length, doubled to the next.
  defp codes(counts, symbols) do
    {table, _code, _left} =
      counts
      |> Enum.with_index(1)
      |> Enum.reduce({%{}, 0, symbols}, fn {n, len}, {table, code, left} ->
        {these, left} = Enum.split(left, n)

        table =
          these
          |> Enum.with_index(code)
          |> Enum.reduce(table, fn {sym, c}, t -> Map.put(t, {len, c}, sym) end)

        {table, (code + n) * 2, left}
      end)

    table
  end

  defp frame(<<8, height::16, width::16, n, comps::binary>>) when n in [1, 3] do
    comps = for <<id, h::4, v::4, tq <- comps>>, do: %{id: id, h: h, v: v, tq: tq}
    # One component is never interleaved: its blocks go one by one.
    comps = if n == 1, do: Enum.map(comps, &%{&1 | h: 1, v: 1}), else: comps
    {:ok, %{width: width, height: height, comps: comps}}
  end

  defp frame(<<precision, _::binary>>) when precision != 8, do: {:error, "#{precision}-bit JPEG"}
  defp frame(_body), do: {:error, "CMYK JPEG not supported"}

  # ── the scan ──

  defp scan(_body, _data, %{frame: nil}), do: {:error, "no image header"}

  defp scan(<<ns, rest::binary>>, data, %{frame: frame} = s) do
    if ns != length(frame.comps) do
      {:error, "multi-scan JPEG not supported"}
    else
      selectors =
        for <<id, td::4, ta::4 <- binary_part(rest, 0, ns * 2)>>, into: %{}, do: {id, {td, ta}}

      comps =
        for c <- frame.comps do
          {td, ta} = Map.fetch!(selectors, c.id)

          Map.merge(c, %{
            dc: Map.fetch!(s.huff, {0, td}),
            ac: Map.fetch!(s.huff, {1, ta}),
            q: Map.fetch!(s.q, c.tq)
          })
        end

      hmax = comps |> Enum.map(& &1.h) |> Enum.max()
      vmax = comps |> Enum.map(& &1.v) |> Enum.max()
      mcux = ceil_div(frame.width, 8 * hmax)
      mcuy = ceil_div(frame.height, 8 * vmax)
      coefs = mcus(entropy(data, [], []), comps, s.ri, mcux * mcuy)

      planes =
        for {c, bin} <- Enum.zip(comps, coefs) do
          bin
          |> plane(c, mcux, mcuy)
          |> upsample(div(vmax, c.v), div(hmax, c.h))
          |> Nx.slice([0, 0], [frame.height, frame.width])
        end

      {:ok, %{width: frame.width, height: frame.height, rgb: rgb(planes)}}
    end
  end

  # The entropy-coded data up to the end marker: stuffed 0xFF00 bytes
  # unstuffed, split at the restart markers (each part starts byte-aligned).
  defp entropy(data, part, parts) do
    case :binary.match(data, <<0xFF>>) do
      :nomatch ->
        Enum.reverse([IO.iodata_to_binary([part, data]) | parts])

      {pos, 1} ->
        <<before::binary-size(^pos), 0xFF, next, rest::binary>> = data

        cond do
          next == 0x00 -> entropy(rest, [part, before, 0xFF], parts)
          next in 0xD0..0xD7 -> entropy(rest, [], [IO.iodata_to_binary([part, before]) | parts])
          next == 0xFF -> entropy(<<0xFF, rest::binary>>, [part, before], parts)
          true -> Enum.reverse([IO.iodata_to_binary([part, before]) | parts])
        end
    end
  end

  # Every MCU of every part: per component, its blocks' 64 coefficients
  # (zigzag order) as one binary of s32.
  defp mcus(parts, comps, ri, total) do
    empty = Enum.map(comps, fn _ -> [] end)

    {blocks, _left} =
      Enum.reduce(parts, {empty, total}, fn bits, {blocks, left} ->
        count = if ri > 0, do: min(ri, left), else: left
        zero = Enum.map(comps, fn _ -> 0 end)

        {blocks, _bits, _preds} =
          Enum.reduce(1..count//1, {blocks, bits, zero}, fn _, acc -> mcu(acc, comps) end)

        {blocks, left - count}
      end)

    Enum.map(blocks, &(&1 |> Enum.reverse() |> IO.iodata_to_binary()))
  end

  # One MCU: each component's h × v blocks, the DC predicted per component.
  defp mcu({blocks, bits, preds}, comps) do
    {blocks, bits, preds} =
      [comps, blocks, preds]
      |> Enum.zip()
      |> Enum.reduce({[], bits, []}, fn {c, acc, pred}, {done, bits, preds} ->
        {acc, bits, pred} =
          Enum.reduce(1..(c.h * c.v), {acc, bits, pred}, fn _, {acc, bits, pred} ->
            {coefs, bits, pred} = block(bits, c, pred)
            {[for(v <- coefs, into: <<>>, do: <<v::32-signed-native>>) | acc], bits, pred}
          end)

        {[acc | done], bits, [pred | preds]}
      end)

    {Enum.reverse(blocks), bits, Enum.reverse(preds)}
  end

  defp block(bits, c, pred) do
    {size, bits} = huff(bits, c.dc, 1, 0)
    {diff, bits} = extend(bits, size)
    {ac, bits} = ac(bits, c.ac, 1, [])
    {[pred + diff | ac], bits, pred + diff}
  end

  defp ac(bits, _table, k, acc) when k > 63, do: {Enum.reverse(acc), bits}

  defp ac(bits, table, k, acc) do
    {rs, bits} = huff(bits, table, 1, 0)
    {run, size} = {div(rs, 16), rem(rs, 16)}

    cond do
      # 16 zeros.
      size == 0 and run == 15 ->
        ac(bits, table, k + 16, zeros(16) ++ acc)

      # End of block: zeros to the end.
      size == 0 ->
        {Enum.reverse(acc, zeros(64 - k)), bits}

      true ->
        with(
          {v, bits} <- extend(bits, size),
          do: ac(bits, table, k + run + 1, [v | zeros(run) ++ acc])
        )
    end
  end

  defp zeros(n), do: List.duplicate(0, n)

  # A Huffman code, one bit at a time (codes are at most 16 bits long).
  defp huff(<<bit::1, rest::bitstring>>, table, len, code) when len <= 16 do
    code = code * 2 + bit

    case Map.fetch(table, {len, code}) do
      {:ok, symbol} -> {symbol, rest}
      :error -> huff(rest, table, len + 1, code)
    end
  end

  # `size` bits as a signed value (the top bit 0 means negative).
  defp extend(bits, 0), do: {0, bits}

  defp extend(bits, size) do
    <<v::size(^size), rest::bitstring>> = bits
    if v < Integer.pow(2, size - 1), do: {v - Integer.pow(2, size) + 1, rest}, else: {v, rest}
  end

  # ── pixels ──

  # A component's blocks, dequantized, inverse-DCT'd and laid out as a
  # plane of mcuy·v·8 × mcux·h·8 samples.
  defp plane(bin, c, mcux, mcuy) do
    n = div(byte_size(bin), 256)
    m = Nx.tensor(@idct, type: :f32)

    bin
    |> Nx.from_binary(:s32)
    |> Nx.reshape({n, 64})
    |> Nx.multiply(Nx.tensor(c.q, type: :s32))
    |> Nx.take(Nx.tensor(@natural), axis: 1)
    |> Nx.reshape({n, 8, 8})
    |> Nx.as_type(:f32)
    # f[y][x] = Σv Σu m[v][y] F[v][u] m[u][x]
    |> Nx.dot([2], m, [0])
    |> Nx.dot([1], m, [0])
    |> Nx.transpose(axes: [0, 2, 1])
    |> Nx.add(128)
    |> Nx.reshape({mcuy, mcux, c.v, c.h, 8, 8})
    |> Nx.transpose(axes: [0, 2, 4, 1, 3, 5])
    |> Nx.reshape({mcuy * c.v * 8, mcux * c.h * 8})
  end

  defp upsample(plane, 1, 1), do: plane

  defp upsample(plane, sy, sx) do
    {h, w} = Nx.shape(plane)

    plane
    |> Nx.reshape({h, 1, w, 1})
    |> Nx.broadcast({h, sy, w, sx})
    |> Nx.reshape({h * sy, w * sx})
  end

  defp rgb([y]), do: [y, y, y] |> Nx.stack(axis: 2) |> Nx.clip(0, 255)

  defp rgb([y, cb, cr]) do
    cb = Nx.subtract(cb, 128)
    cr = Nx.subtract(cr, 128)
    r = Nx.add(y, Nx.multiply(cr, 1.402))
    g = y |> Nx.subtract(Nx.multiply(cb, 0.344136)) |> Nx.subtract(Nx.multiply(cr, 0.714136))
    b = Nx.add(y, Nx.multiply(cb, 1.772))
    [r, g, b] |> Nx.stack(axis: 2) |> Nx.clip(0, 255)
  end

  defp ceil_div(a, b), do: div(a + b - 1, b)
end
