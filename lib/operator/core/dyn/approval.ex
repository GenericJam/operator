defmodule Operator.Core.Dyn.Approval do
  @moduledoc """
  The approval gate on changing what runs (docs/DESIGN.md §2, step 5):
  activating a proposed generation, or reverting to a chosen one by hand.

  The UI asks the configured implementation for a token once the human
  approved (`request/1`); `Operator.Core.Dyn.Keeper` asks the same
  implementation to `verify/2` it before it changes anything. A token is
  for one subject: approving generation 5 doesn't activate generation 6.
  Automatic reverts (crashes on probation, boot probation) need none.

  The production implementation is `Operator.Core.Dyn.Approval.Biometric`.
  Tests configure their own (`approval:` option of the Keeper).
  """

  @type subject :: {:activate, pos_integer()} | {:revert_to, non_neg_integer()}
  @type token :: term()

  @doc "Asks the human to approve `subject`; a token if they did."
  @callback request(subject()) :: {:ok, token()} | {:error, term()}

  @doc "Is `token` a valid approval of `subject`?"
  @callback verify(token(), subject()) :: :ok | {:error, term()}
end

defmodule Operator.Core.Dyn.Approval.Biometric do
  @moduledoc """
  The production approval: a fingerprint or face check (mob_biometric) in
  the screen that shows the proposal, which then asks for the token.

  **Not wired yet**: the prompt belongs to the chat screen's approval card,
  which doesn't exist yet. Until it does, nothing is approved:
  `request/1` and `verify/2` both answer `{:error, :approval_required}`, so
  no generation can be activated or reverted to by hand on the phone.
  """
  @behaviour Operator.Core.Dyn.Approval

  @impl true
  def request(_subject), do: {:error, :approval_required}

  @impl true
  def verify(_token, _subject), do: {:error, :approval_required}
end
