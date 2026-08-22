defmodule CodeMySpec.Integrations.Providers.OpenAI.BrowserAuth.CallbackPlug do
  @moduledoc """
  The one request this listener exists to answer.

  Runs on `localhost:1455` for the length of a login and nothing else. It sends
  the code back to the process waiting on it and renders something the person
  can read, because the browser tab is where they are looking when it finishes —
  a blank page or a raw JSON blob reads as a failure even when it worked.

  `state` is compared before the code is accepted. A callback carrying a state
  we did not issue is a cross-site request rather than a login, and answering it
  would hand somebody else's authorization code to the waiting process.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{request_path: "/auth/callback"} = conn, %{state: state, reply_to: pid}) do
    conn = fetch_query_params(conn)

    conn.query_params
    |> verdict(state)
    |> respond(conn, pid)
  end

  def call(conn, _opts), do: send_resp(conn, 404, page("Not found", "Nothing lives here."))

  # An error from OpenAI is reported as OpenAI's, not swallowed into a generic
  # failure — "access_denied" means the human said no, and telling them we could
  # not reach the provider would be a lie.
  defp verdict(%{"error" => error}, _state), do: {:error, error}
  defp verdict(%{"state" => got}, state) when got != state, do: {:error, :state_mismatch}
  defp verdict(%{"code" => code}, _state) when is_binary(code) and code != "", do: {:ok, code}
  defp verdict(_params, _state), do: {:error, :missing_code}

  defp respond({:ok, code}, conn, pid) do
    send(pid, {:openai_oauth_code, code})

    send_resp(
      conn,
      200,
      page("ChatGPT connected", "You can close this tab and go back to CodeMySpec.")
    )
  end

  defp respond({:error, reason}, conn, pid) do
    send(pid, {:openai_oauth_error, reason})

    send_resp(
      conn,
      400,
      page("That did not complete", "Go back to CodeMySpec and start the connection again.")
    )
  end

  defp page(heading, body) do
    """
    <!doctype html>
    <meta charset="utf-8">
    <title>#{heading}</title>
    <style>
      body { font: 16px/1.5 system-ui, sans-serif; margin: 4rem auto; max-width: 32rem; padding: 0 1rem; }
      h1 { font-size: 1.25rem; }
      p { color: #444; }
    </style>
    <h1>#{heading}</h1>
    <p>#{body}</p>
    """
  end
end
