defmodule CodeMySpec.Users.Scope do
  @moduledoc """
  Defines the scope of the caller to be used throughout the app.

  The `CodeMySpec.Users.Scope` allows public interfaces to receive
  information about the caller, such as if the call is initiated from an
  end-user, and if so, which user. Additionally, such a scope can carry fields
  such as "super user" or other privileges for use as authorization, or to
  ensure specific code paths can only be access for a given scope.

  It is useful for logging as well as for scoping pubsub subscriptions and
  broadcasts when a caller subscribes to an interface or performs a particular
  action.

  Feel free to extend the fields on this struct to fit the needs of
  growing application requirements.

  This is a pure data contract. Keep it free of dependencies because nearly
  every context takes a scope.
  """

  use Boundary, top_level?: true, deps: [], exports: :all

  defstruct user: nil,
            user_id: nil,
            active_account: nil,
            active_account_id: nil,
            active_project: nil,
            active_project_id: nil,
            active_working_copy_id: nil,
            cwd: nil,
            environment: nil

  @type t :: %__MODULE__{
          user: struct() | nil,
          user_id: binary() | integer() | nil,
          active_account: struct() | nil,
          active_account_id: binary() | nil,
          active_project: struct() | nil,
          active_project_id: binary() | nil,
          active_working_copy_id: binary() | nil,
          cwd: String.t() | nil,
          environment: struct() | nil
        }
end
