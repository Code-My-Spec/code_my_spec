defmodule CodeMySpecWeb.UserSocket do
  use Phoenix.Socket
  require Logger

  alias CodeMySpec.Accounts
  alias CodeMySpec.Devices
  alias CodeMySpec.Projects
  alias CodeMySpec.UserPreferences
  alias CodeMySpec.Users
  alias ExOauth2Provider.AccessTokens

  # A Socket handler
  #
  # It's possible to control the websocket connection and
  # assign values that can be accessed by your channel topics.

  ## Channels
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
    allow_sandbox(connect_info)

    case AccessTokens.get_by_token(token, otp_app: :code_my_spec) do
      %{resource_owner_id: user_id} = access_token ->
        if AccessTokens.is_accessible?(access_token) do
          connect_as(access_token, user_id, socket)
        else
          Logger.warning(
            "[UserSocket] connect refused — token expired/revoked #{caller(token, connect_info)}"
          )

          {:error, :token_expired}
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

    {:error, :missing_token}
  end

  # A token issued to a dev box connects as that box (story 1131): no user, and
  # an id of its own so revoking it can end exactly this box's connections.
  defp connect_as(%{device_id: device_id}, _user_id, socket) when is_binary(device_id) do
    case Devices.active_dev_box(device_id) do
      nil ->
        {:error, :token_expired}

      box ->
        Logger.info("[UserSocket] connect ok dev box=#{box.id}")

        {:ok,
         socket
         |> assign(:device_id, box.id)
         |> assign(:scope, %CodeMySpec.Users.Scope{active_account_id: box.account_id})}
    end
  end

  defp connect_as(access_token, user_id, socket) do
    user = Users.get_user!(user_id)
    scope = UserPreferences.scope_for(user)

    Logger.info("[UserSocket] connect ok user_id=#{user.id}")

    {:ok,
     socket
     |> assign(:user_id, user.id)
     |> assign(:oauth_application_id, access_token.application_id)
     |> assign(:scope, scope)}
  end

  # The test's own database connection, for a socket a test opened.
  #
  # The endpoint's `Phoenix.Ecto.SQL.Sandbox` plug does this for HTTP; a
  # websocket's connect and every channel under it run in processes no test
  # started, so the test sends its sandbox metadata in the `user-agent` and this
  # allows the transport process. Channels and their tasks inherit through
  # `$callers`. Compiled out unless `:sql_sandbox` is set, which only test does.
  if Application.compile_env(:code_my_spec, :sql_sandbox) do
    defp allow_sandbox(connect_info),
      do: Phoenix.Ecto.SQL.Sandbox.allow(connect_info[:user_agent], Ecto.Adapters.SQL.Sandbox)
  else
    defp allow_sandbox(_connect_info), do: :ok
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
  def id(%{assigns: %{device_id: device_id}}), do: "dev_box:#{device_id}"

  def id(%{assigns: %{oauth_application_id: application_id, user_id: user_id}})
      when is_integer(application_id),
      do: "oauth_client:#{application_id}:#{user_id}"

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

        {:error, :project_has_no_account}

      nil ->
        Logger.warning(
          "[UserSocket] connect refused — token not found #{caller(token, connect_info)}"
        )

        {:error, :token_not_found}
    end
  end

  defp owned(project, %{} = user, socket, _token, _connect_info) do
    Logger.info("[UserSocket] connect ok via deploy key project_id=#{project.id}")

    {:ok,
     socket
     |> assign(:user_id, user.id)
     |> assign(:scope, UserPreferences.scope_for(user))
     |> assign(:deploy_key_project_id, project.id)}
  end

  defp owned(project, _no_owner, _socket, token, connect_info) do
    Logger.warning(
      "[UserSocket] connect refused — account #{project.account_id} has no owner, " <>
        "so project #{project.id}'s deploy key cannot act for anyone " <>
        "#{caller(token, connect_info)}"
    )

    {:error, :no_account_owner}
  end

  @doc """
  The 403 an un-upgraded websocket connection gets when `connect/3` refuses it
  with `{:error, reason}` -- configured as this socket's `:error_handler`
  (`endpoint.ex`). Stock Phoenix (`Phoenix.Transports.WebSocket.handle_error/2`)
  discards the reason and always sends an empty body, which is why a harness's
  own log could only say the far side said no (issue 62377cc3) -- naming the
  caller server-side (d96809d4) still left the CALLER unable to tell a
  permanent refusal (its credential is gone) from a transient one (network,
  timeout) apart, so it retried a dead credential forever on the same backoff
  as a live one.

  The reason is set as a response HEADER, not only the JSON body: the
  harness's websocket client (Slipstream, backed by Mint) reports a refused
  upgrade from the raw HTTP response parts it decodes itself
  (`[{:status, ref, status}, {:headers, ref, headers} | _maybe_done]` in
  `Slipstream.Connection.Pipeline`) and keeps the status and headers in its
  own `failure_info`, but the match discards everything after headers --
  `_maybe_done`, which is where a response body's `{:data, ...}`/`{:done,
  ...}` parts would be. A header survives that trip; a body does not.
  """
  @spec handle_connect_error(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def handle_connect_error(conn, reason) do
    conn
    |> Plug.Conn.put_resp_header("x-connect-refusal-reason", to_string(reason))
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(403, Jason.encode!(%{"error" => to_string(reason)}))
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

  # Says what it did get. "unreported" on its own is a dead end — it looks like
  # the transport was mounted without `connect_info` and gives no way to tell
  # that apart from a transport that supplied something else, which is exactly
  # where the first reading of this got stuck.
  defp peer(connect_info) when is_map(connect_info),
    do: "peer=unreported(connect_info=#{inspect(Map.keys(connect_info))})"

  defp peer(other), do: "peer=unreported(#{inspect(other)})"
end
