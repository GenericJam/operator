defmodule Operator.Core.Images do
  @moduledoc """
  Pictures for the model: a downscaled upright JPEG of a photo (from a
  file, an Android `content://` URI or an iOS `ph://` asset id) and what
  its EXIF says (when it was taken, where, the camera), through
  `MobPhotos.thumbnail/2`. A tool puts the bytes in its result
  (`{:ok, {:images, [{mime, bytes}], text}}`, `Operator.Core.ToolRunner`).

  Without the NIF (the host, tests) a small JPEG, PNG, GIF or WebP file
  goes as it is. `ctx[:thumbnail]` replaces the call
  (`(source, opts) -> {:ok, info} | {:error, term}`).
  """

  # Claude scales anything longer than ~1568 px down anyway.
  @max_size 1568
  @quality 80
  # Raw pictures sent unscaled stay well under the providers' 5 MB per image.
  @raw_limit 3_500_000

  @type picture :: %{mime: String.t(), bytes: binary(), info: map()}

  @spec for_model(String.t(), map()) :: {:ok, picture()} | {:error, String.t()}
  def for_model(source, ctx \\ %{}) do
    thumbnail = Map.get(ctx, :thumbnail, &thumbnail/2)

    case thumbnail.(source, max_size: @max_size, quality: @quality) do
      {:ok, %{path: path} = info} ->
        scaled(source, path, info)

      {:error, :unavailable} ->
        raw(source)

      {:error, reason} ->
        {:error, "Couldn't open #{source} as a picture: #{inspect(reason)}"}
    end
  end

  defp scaled(source, path, info) do
    read = File.read(path)
    _ = if path != source, do: File.rm(path)

    case read do
      {:ok, bytes} -> {:ok, %{mime: "image/jpeg", bytes: bytes, info: info}}
      {:error, reason} -> {:error, "Couldn't read the scaled picture: #{reason}"}
    end
  end

  defp thumbnail(source, opts) do
    MobPhotos.thumbnail(source, opts)
  rescue
    _ in [UndefinedFunctionError, ErlangError] -> {:error, :unavailable}
  end

  defp raw(source) do
    mime = mime(source)

    with true <- mime != nil || {:error, "#{source} isn't a JPEG, PNG, GIF or WebP picture."},
         {:ok, %File.Stat{size: size}} <- File.stat(source),
         true <- size <= @raw_limit || {:error, "#{source} is too big to show (#{size} bytes)."},
         {:ok, bytes} <- File.read(source) do
      {:ok, %{mime: mime, bytes: bytes, info: %{size: size}}}
    else
      {:error, reason} when is_atom(reason) -> {:error, "Couldn't read #{source}: #{reason}"}
      {:error, _text} = error -> error
    end
  end

  @doc "The picture MIME type a model takes, from the file name, or nil."
  @spec mime(String.t()) :: String.t() | nil
  def mime(path) do
    case path |> Path.extname() |> String.downcase() do
      ext when ext in [".jpg", ".jpeg"] -> "image/jpeg"
      ".png" -> "image/png"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      _ -> nil
    end
  end

  @doc "Is this a picture a phone makes or keeps (by name)?"
  @spec picture?(String.t()) :: boolean()
  def picture?(path) do
    mime(path) != nil or
      String.downcase(Path.extname(path)) in [".heic", ".heif", ".bmp", ".dng", ".tif", ".tiff"]
  end

  @doc "One line about a picture's metadata, for the model: size, when, where, camera."
  @spec describe(map()) :: String.t()
  def describe(info) do
    [
      size(info),
      info[:taken_at] && "taken #{info[:taken_at]}",
      gps(info),
      camera(info)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp size(%{orig_width: w, orig_height: h}) when is_integer(w) and w > 0, do: "#{w}×#{h}"
  defp size(%{width: w, height: h}) when is_integer(w) and w > 0, do: "#{w}×#{h}"
  defp size(_), do: nil

  defp gps(%{latitude: lat, longitude: lon} = info) when is_number(lat) and is_number(lon) do
    alt = if is_number(info[:altitude]), do: ", altitude #{round(info[:altitude])} m", else: ""
    "GPS #{Float.round(lat * 1.0, 6)}, #{Float.round(lon * 1.0, 6)}#{alt}"
  end

  defp gps(_), do: "no GPS in the file"

  defp camera(info) do
    case Enum.reject([info[:make], info[:model]], &(&1 in [nil, ""])) do
      [] -> nil
      parts -> Enum.join(parts, " ")
    end
  end
end
