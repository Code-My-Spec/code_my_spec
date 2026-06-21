defmodule CodeMySpec.ProjectUsers.User do
  @moduledoc """
  A user registered for a project's target application, as read live from that
  app's CodeMySpec users endpoint. Never persisted in CodeMySpec — this is an
  in-memory projection of the remote response.
  """

  @enforce_keys [:email]
  defstruct [:email, :registered_at]

  @type t :: %__MODULE__{
          email: String.t(),
          registered_at: DateTime.t() | nil
        }
end
