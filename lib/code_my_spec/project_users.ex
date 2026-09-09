defmodule CodeMySpec.ProjectUsers do
  @moduledoc """
  Reads the list of users registered for a project's target application.

  The list is fetched live from the target app's `GET /api/cms/users` endpoint
  using the project's `client_api_url` and `deploy_key`, and is never stored in
  CodeMySpec — this context is a read-through projection. It is the future home
  for enriched user / ICP marketing data.
  """

  use Boundary, top_level?: true, deps: [CodeMySpec.Projects], exports: :all

  alias CodeMySpec.Projects.Project
  alias CodeMySpec.ProjectUsers.{Client, Page}

  @doc """
  Lists registered users for a project, one page at a time.

  Returns `{:error, :not_configured}` when the project has no
  `client_api_url`/`deploy_key`, `{:error, :unauthorized}` when the target app
  rejects the deploy key, and `{:error, :unreachable}` when it can't be reached.
  """
  @spec list_registered_users(Project.t(), pos_integer()) ::
          {:ok, Page.t()} | {:error, :not_configured | :unauthorized | :unreachable | term()}
  def list_registered_users(project, page \\ 1)

  def list_registered_users(%Project{client_api_url: url, deploy_key: key}, page)
      when is_binary(url) and url != "" and is_binary(key) and key != "" do
    Client.list_registered_users(url, key, page)
  end

  def list_registered_users(%Project{}, _page), do: {:error, :not_configured}
end
