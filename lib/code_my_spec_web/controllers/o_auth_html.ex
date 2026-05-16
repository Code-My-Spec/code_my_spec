defmodule CodeMySpecWeb.OAuthHTML do
  @moduledoc """
  OAuth2 HTML views
  """

  use CodeMySpecWeb, :html

  embed_templates "oauth_html/*"

  @doc """
  Returns a human-readable description for OAuth scopes
  """
  def scope_description(scope) do
    case scope do
      "read" -> "Read access to your data"
      "write" -> "Write access to your data"
      "stories:read" -> "Read your stories"
      "stories:write" -> "Create and modify your stories"
      "projects:read" -> "Read your projects"
      _ -> scope
    end
  end
end
