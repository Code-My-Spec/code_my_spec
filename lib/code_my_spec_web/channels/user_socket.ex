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
  def connect(%{"token" => token}, socket, connect_info) do
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
          Logger.warning(
            "[UserSocket] connect refused — token expired/revoked #{caller(token, connect_info)}"
          )

          :error
        end

      nil ->
        connect_with_deploy_key(token, socket, connect_info)
    end
  end

  def connect(params, _socket, connect_info) do
    Logger.warning(
      "[UserSocket] connect refused — missing token " <>
        "(params keys: #{inspect(Map.keys(params))}) #{peer(connect_info)}"
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
  defp connect_with_deploy_key(token, socket, connect_info) do
    case Projects.get_project_by_deploy_key(token) do
      %{account_id: account_id} = project when not is_nil(account_id) ->
        owned(project, Accounts.get_account_owner(account_id), socket, token, connect_info)

      %{id: id} ->
        # Not a credential problem, and saying "token not found" sent the
        # operator to check a key that was fine. The key resolved; the project
        # it names has no account, so there is no owner to act as.
        Logger.warning(
          "[UserSocket] connect refused — deploy key resolves to project #{id}, " <>
            "which has no account #{caller(token, connect_info)}"
        )

        :error

      nil ->
        Logger.warning(
          "[UserSocket] connect refused — token not found #{caller(token, connect_info)}"
        )

        :error
    end
  end

  defp owned(project, %{} = user, socket, _token, _connect_info) do
    Logger.info("[UserSocket] connect ok via deploy key project_id=#{project.id}")

    {:ok,
     socket
     |> assign(:user_id, user.id)
     |> assign(:scope, Scope.for_user(user))
     |> assign(:deploy_key_project_id, project.id)}
  end

  defp owned(project, _no_owner, _socket, token, connect_info) do
    Logger.warning(
      "[UserSocket] connect refused — account #{project.account_id} has no owner, " <>
        "so project #{project.id}'s deploy key cannot act for anyone " <>
        "#{caller(token, connect_info)}"
    )

    :error
  end

  # Enough to identify the credential, and nothing that could be replayed.
  #
  # A refusal that names no token is unusable when several are in flight: on one
  # night this logged "token not found" 273 times while other keys connected
  # fine in the same second, and nothing in it said which caller to look at
  # (`d96809d4`). The digest is matchable — hash a key you suspect and compare —
  # without the log carrying any part of the secret. The shape is there because
  # the two forms in use look nothing alike (`dk_`-prefixed, and 128 hex
  # characters), and a key of the wrong shape names the wrong source outright.
  defp caller(token, connect_info) do
    "key=#{shape(token)}:#{digest(token)} #{peer(connect_info)}"
  end

  defp digest(token) when is_binary(token) do
    :sha256 |> :crypto.hash(token) |> Base.encode16(case: :lower) |> binary_part(0, 12)
  end

  defp shape("dk_" <> _rest), do: "dk"
  defp shape(token) when is_binary(token), do: "len#{byte_size(token)}"

  defp peer(%{peer_data: %{address: address}} = connect_info) do
    "peer=#{:inet.ntoa(address)} agent=#{inspect(connect_info[:user_agent])}"
  end

  # A transport that was mounted without `connect_info`, which is worth saying
  # rather than leaving a blank where the peer should be.
  defp peer(_connect_info), do: "peer=unreported"
end
