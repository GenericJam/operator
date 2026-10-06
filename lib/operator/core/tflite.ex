defmodule Operator.Core.Tflite do
  @moduledoc """
  TensorFlow Lite on the phone's accelerator, for the agent's Dyn code
  (front screens and tools may call this module) and the Core:
  `NxTfliteMob` with the best delegate the phone has.

    * Android: NNAPI on the vendor's GPU driver. The accelerator's name
      depends on the chip (`qti-gpu` on Snapdragon, `mtk-gpu_shim` on
      MediaTek, `google-edgetpu` on Pixels, ...); `load/2` tries them in
      turn (NNAPI may not fall back to its CPU path) and then XNNPACK, the
      CPU, and says which one took the model.
    * iOS: Core ML (the Neural Engine or the GPU), then XNNPACK.

  A small model ships with the app: MobileNet v1 0.25/128 (ImageNet, float:
  input 1×128×128×3 f32 scaled to [-1, 1], output 1×1001 class scores).
  `bundled_model/0` writes it into the workspace (`models/`) once, so Dyn
  code reads it like any file (`Operator.Core.Files.read/1`).
  """

  alias Operator.Core.Files
  alias Operator.Core.Term

  @model_name "mobilenet_v1_0.25_128.tflite"
  # Embedded: on the phone the app's priv/ isn't reachable (Operator.Core.Docs).
  # credo:disable-for-next-line
  @model_path Path.expand("../../../priv/tflite/#{@model_name}", __DIR__)
  @external_resource @model_path
  @model File.read!(@model_path)

  @android_accelerators ["qti-gpu", "mtk-gpu_shim", "google-edgetpu", "samsung-gpu"]

  @type delegate :: String.t()

  @doc "The delegate options to try on this platform, best first."
  @spec candidates(atom()) :: [keyword()]
  def candidates(platform \\ Term.platform())

  def candidates(:android) do
    for(a <- @android_accelerators, do: [delegate: "nnapi", accelerator: a, allow_fp16: true]) ++
      [[delegate: "xnnpack"]]
  end

  def candidates(:ios), do: [[delegate: "coreml", coreml_ane_only: false], [delegate: "xnnpack"]]
  def candidates(_host), do: [[delegate: "xnnpack"]]

  @doc """
  Loads a `.tflite` model on the first delegate that takes it (or with
  `opts` given, on that one). Answers the handle and which delegate it is
  (`"nnapi/qti-gpu"`, `"coreml"`, `"xnnpack"`, ...).
  """
  @spec load(binary(), keyword() | nil) :: {:ok, reference(), delegate()} | {:error, String.t()}
  def load(model, opts \\ nil) when is_binary(model) do
    tries = if opts, do: [opts], else: candidates()

    Enum.reduce_while(tries, {:error, "no delegate took the model"}, fn try_opts, last ->
      case NxTfliteMob.load_module(model, try_opts) do
        {:ok, handle} -> {:halt, {:ok, handle, describe(try_opts)}}
        {:error, why} -> {:cont, merge_error(last, try_opts, why)}
      end
    end)
  end

  defp merge_error({:error, "no delegate" <> _}, opts, why),
    do: {:error, "#{describe(opts)}: #{why}"}

  defp merge_error({:error, text}, opts, why), do: {:error, "#{text}; #{describe(opts)}: #{why}"}

  defp describe(opts) do
    case {opts[:delegate], opts[:accelerator]} do
      {d, nil} -> d
      {d, a} -> "#{d}/#{a}"
    end
  end

  @doc "Runs the model: one binary per input tensor in, one per output out (`NxTfliteMob.call/2`)."
  @spec run(reference(), [binary()]) :: {:ok, [binary()]} | {:error, term()}
  def run(handle, inputs), do: NxTfliteMob.call(handle, inputs)

  @doc "Frees the model and its delegate."
  @spec release(reference()) :: :ok
  def release(handle), do: NxTfliteMob.release_module(handle)

  @doc "The bundled MobileNet's path in the workspace (written there the first time)."
  @spec bundled_model() :: {:ok, Path.t()} | {:error, term()}
  def bundled_model do
    path = Path.join([Files.workspace(), "models", @model_name])

    if File.regular?(path) and File.stat!(path).size == byte_size(@model) do
      {:ok, path}
    else
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(path, @model),
           do: {:ok, path}
    end
  end

  @doc "The bundled MobileNet's bytes."
  @spec bundled_model_bytes() :: binary()
  def bundled_model_bytes, do: @model
end
