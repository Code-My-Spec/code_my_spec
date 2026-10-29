defmodule CodeMySpec.Provisioning.Tools.ConnectProvider do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Integrations
  alias CodeMySpec.Integrations.OAuthHandoff
  alias CodeMySpec.Provisioning.Credentials

  # Named, never `String.to_existing_atom/1` off the wire: these are the
  # providers whose consent a person can give to an agent's request.
  @providers %{"cloudflare" => :cloudflare, "resend" => :resend, "github" => :github}

  @impl true
  def name, do: "connect_provider"

  @impl true
  def description do
    """
    Start connecting Cloudflare, Resend or GitHub, and get the consent link to
    hand to the person.

    The agent asks, the person acts: the link is the provider's own consent
    page, and the token goes from the provider to the server when the person
    approves it. It never passes through the agent, so there is no value for
    the agent to hold or relay. Give the person the link, then call
    `await_provider_connection` to wait until the connection lands.

    Pasted secrets (the Hetzner API token) are not connected this way; they
    stay human-entered on the provisioning page.
    """
  end

  @impl true
  def params do
    %{
      provider:
        {:required,
         {:meta, :string,
          [description: "One of: #{@providers |> Map.keys() |> Enum.join(", ")}."]}}
    }
  end

  @impl true
  def call(%{provider: provider}, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, provider} <- fetch_provider(provider) do
      case connection_status(scope, provider) do
        :connected ->
          already(provider)

        :disconnected ->
          start(provider)

        {:error, reason} ->
          error("could not check the #{provider} connection: #{inspect(reason)}")
      end
    else
      {:error, reason} -> error(reason)
    end
  end

  defp start(provider) do
    case Integrations.authorize_url(provider) do
      {:ok, %{url: url, session_params: session_params}} ->
        :ok =
          OAuthHandoff.park(%{
            session_params: session_params,
            provider: provider,
            flow: :integration
          })

        {:ok,
         "Give the person this link to approve #{provider}, signed in to this app in their " <>
           "browser. It expires in ten minutes.\n\n#{url}\n\n" <>
           "Then call await_provider_connection with provider #{provider}."}

      {:error, reason} ->
        error("could not start the #{provider} connection: #{inspect(reason)}")
    end
  end

  defp already(provider), do: {:ok, "#{provider} is already connected. Nothing to approve."}

  @doc false
  def fetch_provider(name) when is_binary(name) do
    case Map.fetch(@providers, name) do
      {:ok, provider} ->
        {:ok, provider}

      :error ->
        {:error,
         "unknown provider #{inspect(name)}; one of #{Enum.join(Map.keys(@providers), ", ")}"}
    end
  end

  @doc false
  def connected?(scope, provider),
    do: Credentials.stored?(scope, %{kind: :connection, provider: provider})

  defp connection_status(scope, :github) do
    case Integrations.fetch_access_token(scope, :github) do
      {:ok, token} -> check_github_grant(token)
      {:error, reason} when reason in [:not_found, :reauthorize_required] -> :disconnected
      {:error, reason} -> {:error, reason}
    end
  end

  defp connection_status(scope, provider) do
    if connected?(scope, provider), do: :connected, else: :disconnected
  end

  defp check_github_grant(token) do
    opts = [auth: {:bearer, token}, retry: false]
    opts = Keyword.merge(opts, Application.get_env(:code_my_spec, __MODULE__, []))

    case Req.get("https://api.github.com/user", opts) do
      {:ok, %Req.Response{status: 200}} -> :connected
      {:ok, %Req.Response{status: 401}} -> :disconnected
      {:ok, %Req.Response{status: status}} -> {:error, {:github_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp error(reason) when is_binary(reason), do: {:error, reason}
  defp error(reason), do: CodeMySpec.Tools.error(reason)
end
