defmodule Mix.Tasks.Operator.Deliver.Qr do
  @shortdoc "Shows the QR that points the phone at this Mac's update server"
  @moduledoc """
  Points the phone at this Mac's update server (`mix
  operator.deliver.serve`):

      mix operator.deliver.qr                 # this Mac's LAN address, port 8040
      mix operator.deliver.qr --port 8041 --ip 192.168.1.20

  Prints `operator://deliver?endpoint=http://<LAN address>:<port>/deliver&key=…`
  as a QR (`Operator.Deliver.link/2`; `key` is the fingerprint of the
  signing key's public half, `mix operator.deliver.key`). Scan it with the
  phone's camera, any QR app or Diagnostics → Scan QR: if the code is for
  the key the phone's build was made with, Operator shows the address and
  saves it when you tap "Use this server", then checks for updates there.
  Run it again when the Mac's address changes.

  Doesn't start the Operator application.
  """
  use Mix.Task

  alias Mix.Operator.Deliver
  alias Mix.Operator.QR

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [port: :integer, ip: :string])
    port = Keyword.get(opts, :port, Deliver.default_port())

    ip =
      Keyword.get_lazy(opts, :ip, &Deliver.lan_ip/0) ||
        Mix.raise("No private IPv4 address on an interface that is up: pass --ip")

    endpoint = Deliver.endpoint(ip, port)
    public_key = Deliver.public_key(Deliver.read_private_key!())
    link = Operator.Deliver.link(endpoint, public_key)

    QR.print(link)

    Mix.shell().info("""

    Update server: #{endpoint}
    Link: #{link}
    Scan with the phone's camera (or Diagnostics → Scan QR) to check for updates there.
    The phone's build must trust #{public_key} (deployed natively after mix operator.deliver.key).
    """)
  end
end
