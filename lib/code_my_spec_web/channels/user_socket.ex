defmodule CodeMySpecWeb.UserSocket do
  use Phoenix.Socket
  require Logger

  alias CodeMySpec.Accounts
  alias CodeMySpec.Projects
  alias CodeMySpec.Users
  alias CodeMySpec.Users.Scope
  alias ExOauth2Provider.AccessTokens

  # A Socket handler
  #
  # It's possible to control the websocket connection and
  # assign values that can be accessed by your channel topics.

  ## Channels
  channel "vscode:*", CodeMySpecWeb.VSCodeChannel
  channel "session:*", CodeMySpecWeb.SessionChannel
  channel "permission:*", CodeMySpecWeb.PermissionChannel
  channel "issues:*", CodeMySpecWeb.IssuesChannel
  channel "cli:user:*", CodeMySpecWeb.CliChannel
  channel "harness:*", CodeMySpecWeb.HarnessChannel
  channel "harness_project:*", CodeMySpecWeb.HarnessProjectChannel

  # Socket params are passed from the client and can
  # be used to verify and authenticate a user. After
  # verification, you can put default assigns into
  # the socket that will be set for all channels, ie
  #
  #     {:ok, assign(socket, :user_id, verified_user_id)}
  #
  # To deny connection, return `:error` or `{:error, term}`. To control the
  # response the client receives in that case, [define an error handler in the
  # websocket
  # configuration](https://hexdocs.pm/phoenix/Phoenix.Endpoint.html#socket/3-websocket-configuration).
  #
  # See `Phoenix.Token` documentation for examples in
  # performing token verification on connect.
  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case AccessTokens.get_by_token(token, otp_app: :code_my_spec) do
      %{resource_owner_id: user_id} = access_token ->
        if AccessTokens.is_accessible?(access_token) do
          user = Users.get_user!(user_id)
          scope = Scope.for_user(user)

          Logger.info("[UserSocket] connect ok user_id=#{user.id}")

          {:ok,
           socket
           |> assign(:user_id, user.id)
           |> assign(:scope, scope)}
        else
          Logger.warning("[UserSocket] connect refused — token expired/revoked")
          :error
        end

      nil ->
        connect_with_deploy_key(token, socket)
    end
  end

  def connect(params, _socket, _connect_info) do
    Logger.warning(
      "[UserSocket] connect refused — missing token (params keys: #{inspect(Map.keys(params))})"
    )

    :error
  end

  # Socket IDs are topics that allow you to identify all sockets for a given user:
  #
  #     def id(socket), do: "user_socket:#{socket.assigns.user_id}"
  #
  # Would allow you to broadcast a "disconnect" event and terminate
  # all active sockets and channels for a given user:
  #
  #     Elixir.CodeMySpecWeb.Endpoint.broadcast("user_socket:#{user.id}", "disconnect", %{})
  #
  # Returning `nil` makes this socket anonymous.
  @impl true
  def id(_socket), do: nil
  # A sprite has no user and therefore no OAuth token — it holds its project's
  # deploy key and nothing else. Without this it cannot open the harness socket
  # at all, so agent messages never reach the operator inbox and human replies
  # have no route back down.
  #
  # Same trade as `Plugs.DeployKeyOrOAuth`: the key resolves to the project's
  # account owner, because it is their project and their inbox. Tried only after
  # the token lookup misses, so nothing about the user path changes.
  defp connect_with_deploy_key(token, socket) do
    with %{account_id: account_id} = project when not is_nil(account_id) <-
           Projects.get_project_by_deploy_key(token),
         %{} = user <- Accounts.get_account_owner(account_id) do
      Logger.info("[UserSocket] connect ok via deploy key project_id=#{project.id}")

      {:ok,
       socket
       |> assign(:user_id, user.id)
       |> assign(:scope, Scope.for_user(user))
       |> assign(:deploy_key_project_id, project.id)}
    else
      _ ->
        Logger.warning("[UserSocket] connect refused — token not found")
        :error
    end
  end
end
