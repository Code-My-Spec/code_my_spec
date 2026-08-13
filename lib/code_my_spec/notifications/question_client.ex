defmodule CodeMySpec.Notifications.QuestionClient do
  @moduledoc """
  CLI-side client that routes a remote `AskUserQuestion` through the production
  server: `ask/2` posts the questions (which pushes a notification to the user's
  phone) and `await_answer/2` polls until they answer in `QuestionLive.Show`.

  Two credentials work here. A desktop install authenticates as the user, with
  the same OAuth token + server URL pattern as `NotificationClient`. A sprite
  has no user to authenticate as and carries its project's deploy key instead —
  the server resolves that to the project's account owner and raises the
  question to them (`CodeMySpecWeb.Plugs.DeployKeyOrOAuth`).

  The fallback order matters: OAuth first, so a developer running the CLI on
  their own machine is asked as themselves even on a project whose deploy key
  happens to be configured.

  With neither, `ask/2` returns `{:error, :not_configured}` and the caller falls
  back to the terminal — which is the right answer at a keyboard and no answer
  at all in an unattended sprite.
  """

  require Logger

  alias CodeMySpec.Auth.OAuthClient

  @poll_interval_ms 1_500
  @default_timeout_ms 10 * 60 * 1_000

  @doc "Create a remote question request. Returns `{:ok, id}` or `{:error, reason}`."
  @spec ask([map()], String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def ask(questions, title \\ nil, harness_id \\ nil) when is_list(questions) do
    with {:ok, token} <- credential() do
      url = "#{OAuthClient.get_server_url()}/api/questions/ask"
      # The harness, not the session. The asking agent has a scope carrying a
      # working copy; the server turns that into the session running there,
      # the same way it does for a recorded model turn.
      body = %{questions: questions, title: title, harness_id: harness_id}

      case Req.post(url, headers: [{"authorization", "Bearer #{token}"}], json: body) do
        {:ok, %{status: status, body: %{"id" => id}}} when status in [200, 201] ->
          {:ok, id}

        {:ok, %{status: status, body: body}} ->
          Logger.warning("[QuestionClient] ask failed (#{status}): #{inspect(body)}")
          {:error, {:http, status}}

        {:error, reason} ->
          Logger.warning("[QuestionClient] ask transport error: #{inspect(reason)}")
          {:error, reason}
      end
    else
      {:error, _} -> {:error, :not_configured}
    end
  end

  @doc """
  Poll for the answer to a question request until it's answered or the timeout
  elapses. Returns `{:ok, answers}` (a `%{question => answer}` map) or
  `{:error, :timeout}` / `{:error, reason}`.
  """
  @spec await_answer(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def await_answer(id, opts \\ []) do
    deadline = now_ms() + Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    with {:ok, token} <- credential() do
      poll(id, token, deadline)
    else
      {:error, _} -> {:error, :not_configured}
    end
  end

  defp poll(id, token, deadline) do
    url = "#{OAuthClient.get_server_url()}/api/questions/#{id}/status"

    case Req.get(url, headers: [{"authorization", "Bearer #{token}"}]) do
      {:ok, %{status: 200, body: %{"status" => "answered", "answers" => answers}}} ->
        {:ok, answers}

      {:ok, %{status: 200, body: %{"status" => "expired"}}} ->
        {:error, :expired}

      {:ok, %{status: 200}} ->
        wait_and_retry(id, token, deadline)

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        Logger.warning("[QuestionClient] poll transport error: #{inspect(reason)}")
        wait_and_retry(id, token, deadline)
    end
  end

  defp wait_and_retry(id, token, deadline) do
    if now_ms() >= deadline do
      {:error, :timeout}
    else
      Process.sleep(@poll_interval_ms)
      poll(id, token, deadline)
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
  # OAuth if the user is signed in here; otherwise the project's deploy key.
  # `:deploy_key` is set from CMS_DEPLOY_KEY at boot in a sprite and is absent
  # everywhere else, so this changes nothing for a desktop install.
  defp credential do
    case OAuthClient.get_token() do
      {:ok, token} ->
        {:ok, token}

      _ ->
        case Application.get_env(:code_my_spec, :deploy_key) do
          key when is_binary(key) and key != "" -> {:ok, key}
          _ -> {:error, :not_configured}
        end
    end
  end
end
