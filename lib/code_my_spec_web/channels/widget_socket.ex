defmodule CodeMySpecWeb.WidgetSocket do
  @moduledoc """
  Socket the feedback/chat widget connects through from a target application.

  Two credentials are accepted, for two holders:

  - the project's **deploy key**, server-to-server — the widget runs in the
    target app's backend, which holds it, and it never reaches the browser;
  - a short-lived **socket token** from `GET /api/widget/socket_token`, which
    is what the backend hands the browser instead.

  The token exists because the deploy key must not reach a browser and a
  browser still has to connect. It is scoped to sockets by its own salt, so it
  cannot be replayed against the REST surfaces.

  The end-user's identity travels as connect params, not a credential.
  Topic-level authorization happens in `ConversationChannel`.
  """

  use Phoenix.Socket
  require Logger

  alias CodeMySpec.AppTokens
  alias CodeMySpec.Projects

  channel "conversation:*", CodeMySpecWeb.ConversationChannel

  @impl true
  def connect(%{"deploy_key" => deploy_key} = params, socket, _info) when is_binary(deploy_key) do
    # The deploy key is self-identifying via its blind-index hash — the widget
    # presents only the key (server-side); CMS resolves the project from it.
    case Projects.get_project_by_deploy_key(deploy_key) do
      %{account_id: account_id} = project ->
        {:ok,
         socket
         |> assign(:project_id, project.id)
         |> assign(:account_id, account_id)
         |> assign(:end_user_id, params["user_id"])
         |> assign(:end_user_email, params["user_email"])}

      nil ->
        Logger.warning("[WidgetSocket] connect refused — unknown deploy key")
        :error
    end
  end

  def connect(%{"socket_token" => token} = params, socket, _info) when is_binary(token) do
    case AppTokens.verify_socket_token(token) do
      {:ok, project} ->
        {:ok,
         socket
         |> assign(:project_id, project.id)
         |> assign(:account_id, project.account_id)
         |> assign(:end_user_id, params["user_id"])
         |> assign(:end_user_email, params["user_email"])}

      {:error, reason} ->
        Logger.warning("[WidgetSocket] connect refused — socket token #{reason}")
        :error
    end
  end

  def connect(_params, _socket, _info), do: :error

  @impl true
  def id(_socket), do: nil
end
