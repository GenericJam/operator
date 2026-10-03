defmodule Operator.LoginScanScreenTest do
  # async: false: the native module is swapped through application env and
  # the sign-ins live in the app-wide secure store.
  use Mob.ScreenCase, async: false

  alias Operator.Auth
  alias Operator.Auth.Transfer
  alias Operator.LoginScanScreen
  alias Operator.Test.FakeScanNative

  @moduletag :capture_log

  @creds %{
    "type" => "oauth",
    "access" => "sk-ant-oat01-not-a-real-access-token",
    "refresh" => "sk-ant-ort01-not-a-real-refresh-token",
    "expires" => 1_900_000_000_000,
    "email" => "kevin@example.com"
  }

  setup do
    Application.put_env(:operator, :login_scan_native, FakeScanNative)
    start_supervised!(Auth)
    :ok = Auth.delete(:anthropic)

    # The test's Auth is stopped by now: clear the sign-in through a fresh one.
    on_exit(fn ->
      Application.delete_env(:operator, :login_scan_native)
      {:ok, pid} = Auth.start_link()
      :ok = Auth.delete(:anthropic)
      GenServer.stop(pid)
    end)
  end

  # Scan button → camera permission → scanner → the scanned text.
  defp scan(view, qr) do
    view = render_info(view, {:tap, :scan})
    assert_received :requested_camera
    view = render_info(view, {:permission, :camera, :granted})
    assert_received :scanning
    render_info(view, {:scan, :result, %{type: :qr, value: qr}})
  end

  defp sign_in(view, words),
    do: view |> render_info({:change, :words, words}) |> render_info({:tap, :submit})

  test "scan, type the words: the phone is signed in" do
    {qr, words} = Transfer.seal(:anthropic, @creds)
    view = mount_screen(LoginScanScreen)
    assert_renderable(view)

    view = scan(view, qr)
    assert text(view) =~ "Type the six words"
    assert_renderable(view)

    view = sign_in(view, words)
    assert text(view) =~ "Signed in to Claude (Anthropic) as kevin@example.com"

    assert {:ok, %{"refresh" => refresh, "access" => "", "expires" => 0}} = Auth.get(:anthropic)
    assert refresh == @creds["refresh"]
    assert view |> render_info({:tap, :back}) |> navigated_to() == {:pop}
  end

  test "wrong words are said plainly and can be retyped" do
    {qr, words} = Transfer.seal(:anthropic, @creds)
    [_ | rest] = all = String.split(words, " ")
    other = Enum.find(Transfer.wordlist(), &(&1 not in all))

    view = mount_screen(LoginScanScreen) |> scan(qr) |> sign_in(Enum.join([other | rest], " "))
    assert text(view) =~ "Those words don't open this code"
    assert Auth.get(:anthropic) == :error

    view = sign_in(view, words)
    assert text(view) =~ "Signed in to Claude (Anthropic)"
  end

  test "an expired code sends the user back to scanning" do
    {qr, words} =
      Transfer.seal(:anthropic, @creds, now: System.system_time(:millisecond) - 11 * 60_000)

    view = mount_screen(LoginScanScreen) |> scan(qr) |> sign_in(words)
    assert text(view) =~ "more than 10 minutes old"
    assert find(view, :button, text: "Scan login QR")
    assert Auth.get(:anthropic) == :error
  end

  test "a QR that isn't an Operator code, a refused camera, a cancelled scan" do
    view = mount_screen(LoginScanScreen) |> scan("https://example.com/")
    assert text(view) =~ "isn't an Operator login code"
    refute find(view, :button, text: "Sign in")

    view = view |> render_info({:tap, :scan}) |> render_info({:permission, :camera, :denied})
    assert text(view) =~ "allow it in Settings"
    refute_received :scanning

    view = render_info(view, {:scan, :cancelled})
    assert text(view) =~ "Scan cancelled"
  end
end
