defmodule Operator.Core.Models do
  @moduledoc """
  The models Operator can call right now (menu › model, like omp's
  `/models`): the static catalog filtered to the providers that are signed
  in (`Operator.Auth`).

    * Claude: llm_db's Anthropic models (the catalog
      req_llm resolves them through), retired and deprecated ones left out,
      newest first within Opus, Sonnet, Haiku, then the rest.
    * ChatGPT: the Codex backend serves its own set, which
      llm_db doesn't list; `priv/models/openai_codex.json` is omp's list
      (its source and version are in the file).
  """

  alias Operator.Auth

  # Read at compile time and embedded: Application.app_dir/2 can't resolve
  # priv/ on the device (see Operator.Core.Dyn.Samples).
  # credo:disable-for-next-line
  @codex_file Path.expand("../../../priv/models/openai_codex.json", __DIR__)
  @external_resource @codex_file
  @codex (@codex_file |> File.read!() |> Jason.decode!())["models"]

  @type model :: %{
          provider: Auth.provider(),
          spec: String.t(),
          name: String.t(),
          context: pos_integer() | nil
        }

  @doc """
  `[{provider, signed_in?, models}]` for every provider, in `Auth.providers/0`
  order; a provider that isn't signed in has no models.
  """
  @spec by_provider(map()) :: [{Auth.provider(), boolean(), [model()]}]
  def by_provider(status \\ Auth.status()) do
    for provider <- Auth.providers() do
      signed_in = match?(%{signed_in: true}, status[provider])
      {provider, signed_in, if(signed_in, do: catalog(provider), else: [])}
    end
  end

  @doc "Every model of `provider` in the catalog, whether signed in or not."
  @spec catalog(Auth.provider()) :: [model()]
  def catalog(:anthropic) do
    LLMDB.models(:anthropic)
    |> Enum.reject(&(&1.retired || &1.deprecated))
    |> Enum.map(fn m ->
      %{
        provider: :anthropic,
        spec: "anthropic:" <> m.id,
        name: m.name || m.id,
        context: get_in(m, [Access.key(:limits), :context])
      }
    end)
    |> Enum.sort_by(&claude_order/1)
  end

  def catalog(:openai_codex) do
    for m <- @codex,
        do: %{
          provider: :openai_codex,
          spec: "openai_codex:" <> m["id"],
          name: m["name"],
          context: m["context"]
        }
  end

  def catalog(_other), do: []

  @doc """
  Whether two model specs name the same model, ignoring a dated snapshot
  suffix (`claude-haiku-4-5` is `claude-haiku-4-5-20251001`).
  """
  @spec same?(String.t(), String.t()) :: boolean()
  def same?(a, b), do: undated(a) == undated(b)

  defp undated(spec), do: String.replace(spec, ~r/-\d{8}$/, "")

  @doc """
  What `spec` takes as input (`:text`, `:image`, `:pdf`, ...): llm_db's
  `modalities.input`, looked up once per spec and kept (the loop asks on
  every request). Every model on the Codex backend takes text and pictures
  (omp's catalog); a Claude model llm_db doesn't know (a custom id) takes
  pictures and PDFs like every Claude; anything else unknown, text only.
  """
  @spec inputs(String.t()) :: [atom()]
  def inputs(spec) do
    key = {__MODULE__, :inputs, spec}

    case :persistent_term.get(key, nil) do
      nil ->
        inputs = lookup_inputs(spec)
        :persistent_term.put(key, inputs)
        inputs

      inputs ->
        inputs
    end
  end

  @doc "Does `spec` take pictures?"
  @spec images?(String.t()) :: boolean()
  def images?(spec), do: :image in inputs(spec)

  defp lookup_inputs("openai_codex:" <> _id), do: [:text, :image]

  defp lookup_inputs(spec) do
    case LLMDB.model(spec) do
      {:ok, %{modalities: %{input: [_ | _] = input}}} -> input
      _ -> if String.starts_with?(spec, "anthropic:"), do: [:text, :image, :pdf], else: [:text]
    end
  end

  # Opus, Sonnet, Haiku, then the rest; newest version first in each.
  defp claude_order(%{name: name}) do
    family =
      cond do
        name =~ ~r/opus/i -> 0
        name =~ ~r/sonnet/i -> 1
        name =~ ~r/haiku/i -> 2
        true -> 3
      end

    # 5 is 5.0.0, so 5.5 sorts above it.
    version =
      ~r/\d+/
      |> Regex.scan(name)
      |> List.flatten()
      |> Enum.map(&String.to_integer/1)
      |> Kernel.++([0, 0, 0])
      |> Enum.take(3)
      |> Enum.map(&(-&1))

    {family, version, name}
  end
end
