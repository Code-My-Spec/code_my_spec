defmodule CodeMySpec.Git.Behaviour do
  @moduledoc """
  Behaviour for Git operations
  """

  alias CodeMySpec.Users.Scope

  @type repo_url :: String.t()
  @type path :: String.t()
  @type error_reason :: :not_connected | :unsupported_provider | :invalid_url | term()

  @callback clone(Scope.t(), repo_url(), path()) :: {:ok, path()} | {:error, error_reason()}
  @callback pull(Scope.t(), path()) :: :ok | {:error, error_reason()}
  @callback clone(Scope.t(), repo_url(), path(), term()) ::
              {:ok, path()} | {:error, error_reason() | :environment_not_supported}
  @callback pull(Scope.t(), path(), term()) ::
              :ok | {:error, error_reason() | :environment_not_supported}

  @optional_callbacks clone: 4, pull: 3
end
