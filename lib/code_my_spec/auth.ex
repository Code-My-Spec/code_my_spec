defmodule CodeMySpec.Auth do
  @moduledoc """
  OAuth authentication support: PKCE state, the OAuth2 client/strategy, and
  socket reconnect backoff.

  No functions of its own — this file exists so `CodeMySpec.Auth.*` has a
  boundary to be classified under (`AuthState`, `OAuthClient`, `Strategy`,
  `WebSocketBackoff`), the same shape as `CodeMySpec.McpServers`.
  """

  use Boundary,
    top_level?: true,
    deps: [CodeMySpec.ClientUsers.ClientUser, CodeMySpec.PublicUrl, CodeMySpec.Repo],
    exports: :all
end
