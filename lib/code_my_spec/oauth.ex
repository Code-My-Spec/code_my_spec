defmodule CodeMySpec.Oauth do
  @moduledoc """
  Public API for the OAuth2 authorization server.

  Wraps `ExOauth2Provider`-backed schemas (`Application`,
  `AccessToken`, `AccessGrant`) so the web tier doesn't reach into
  `Repo` directly. Currently exposes just the bits the OAuth /
  Dynamic Client Registration controllers need.
  """

  alias CodeMySpec.Oauth.Application
  alias CodeMySpec.Repo

  @doc """
  Registers a new OAuth2 application (MCP client) with the given
  attributes. Returns `{:ok, %Application{}}` on success or
  `{:error, %Ecto.Changeset{}}` when the metadata fails validation.
  """
  @spec register_application(map()) ::
          {:ok, Application.t()} | {:error, Ecto.Changeset.t()}
  def register_application(attrs) do
    %Application{}
    |> Application.changeset(attrs)
    |> Repo.insert()
  end
end
