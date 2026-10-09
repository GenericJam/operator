defmodule Operator.Core.Dyn.AutoApprove do
  @moduledoc """
  The "approve all" setting: while on, the chat screen activates each
  candidate generation as it arrives instead of showing the approval bar
  (the same activation, so probation and revert-on-crash still apply).
  Only Dyn activations: reverting and cluster joins still ask.

  Kept in `Operator.SecureStore`, not settings.json, so the agent's file
  tools can't flip it. Off by default (and whenever the store can't be
  read). Turning it on takes the human's screen lock: `enable/0` needs a
  fresh confirmation of `subject/0` from the configured approval (in the
  app, `Operator.Core.Dyn.Approval.Biometric`, fed only by the approve
  chip's pass). Turning it off needs nothing. Dyn code can't reach this
  module (`Operator.Core.Dyn.Check`), and no tool calls `enable/0`.
  """

  alias Operator.Core.Dyn
  alias Operator.SecureStore

  @account "dyn:auto_approve"
  @subject {:auto_approve, :on}

  @doc "The approval subject that turns approve-all on."
  @spec subject() :: {:auto_approve, :on}
  def subject, do: @subject

  @doc "Is approve-all on?"
  @spec on?() :: boolean()
  def on?, do: SecureStore.get(@account) == {:ok, "on"}

  @doc "Turns approve-all on, given the human just confirmed `subject/0`."
  @spec enable() :: :ok | {:error, term()}
  def enable do
    with {:ok, _token} <- Dyn.request_approval(@subject),
         do: SecureStore.put(@account, "on")
  end

  @doc "Turns approve-all off."
  @spec disable() :: :ok | {:error, term()}
  def disable, do: SecureStore.delete(@account)
end
