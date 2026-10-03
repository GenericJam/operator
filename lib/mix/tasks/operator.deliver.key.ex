defmodule Mix.Tasks.Operator.Deliver.Key do
  @shortdoc "Creates the key that signs Operator's code updates"
  @moduledoc """
  Creates the Ed25519 key that signs Operator's over-the-air code updates
  (`mix operator.publish`):

      mix operator.deliver.key

  Writes it to `~/.config/operator/deliver_signing.key` (mode 0600; `--out
  PATH` writes elsewhere) and prints its public half. Refuses to overwrite
  an existing key: the phones trust only the key their build was made
  with, so a new one strands them until a native deploy.

  `config/config.exs` reads the public half from that file whenever the
  app is built, so no edit is needed: deploy natively once (`mix
  mob.deploy --native --android`) and the phone trusts updates signed with
  it. Keep the file out of version control and off other machines.

  Doesn't start the Operator application.
  """
  use Mix.Task

  alias Mix.Operator.Deliver

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [out: :string])
    path = opts |> Keyword.get(:out, Deliver.key_path()) |> Path.expand()
    private_key = MobDeliverServer.Manifest.generate_private_key()

    case Deliver.write_private_key(path, private_key) do
      :ok ->
        Mix.shell().info("""
        Wrote the update signing key to #{path} (mode 0600).
        Public key: #{Deliver.public_key(private_key)}

        Next: deploy natively once so the phone trusts it (mix mob.deploy --native --android),
        then mix operator.deliver.serve, mix operator.deliver.qr and mix operator.publish.
        """)

      {:error, :exists} ->
        Mix.raise(
          "#{path} already exists; refusing to replace the signing key " <>
            "(phones trust only the key their build was made with)"
        )

      {:error, reason} ->
        Mix.raise("Couldn't write #{path}: #{:file.format_error(reason)}")
    end
  end
end
