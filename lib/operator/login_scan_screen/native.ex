defmodule Operator.LoginScanScreen.Native do
  @moduledoc """
  The login scan screen's calls into the native layer: the camera
  permission and the QR scanner (mob_scanner). Swappable through
  `config :operator, :login_scan_native, Module` so host tests run without
  the NIFs; on the host they aren't loaded and these return
  `{:error, :unavailable}` instead of raising.
  """

  @doc "Asks for the camera; the answer comes as `{:permission, :camera, :granted | :denied}`."
  @callback request_camera() :: :ok | {:error, term()}
  @doc """
  Opens the full-screen QR scanner; it ends in `{:scan, :result, %{value: text}}`,
  `{:scan, :cancelled}`, `{:scan, :permission_denied}` or `{:scan, :not_available}`.
  """
  @callback scan() :: :ok | {:error, term()}

  @behaviour __MODULE__

  @spec impl() :: module()
  def impl, do: Application.get_env(:operator, :login_scan_native, __MODULE__)

  @impl true
  def request_camera do
    _ = Mob.Permissions.request(nil, :camera)
    :ok
  rescue
    _ in [ErlangError, UndefinedFunctionError] -> {:error, :unavailable}
  end

  @impl true
  def scan do
    _ = MobScanner.scan(nil, formats: [:qr])
    :ok
  rescue
    _ in [ErlangError, UndefinedFunctionError] -> {:error, :unavailable}
  end
end
