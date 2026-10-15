defmodule CodeMySpecDesktop.Application.SetupPage do
  @moduledoc "Renders desktop prerequisite setup without sessions or database access."

  alias CmsHarness.Setup

  def render(status, action_path, app_url) do
    body = content(status, action_path, app_url)
    refresh = refresh(status.phase)

    IO.iodata_to_binary([
      "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>CodeMySpec setup</title>",
      refresh,
      "<style>body{font:16px system-ui;max-width:900px;margin:40px auto;padding:0 24px;background:#f8fafc;color:#172033}section{background:white;border:1px solid #ccd5df;border-radius:10px;padding:20px;margin:16px 0}pre{white-space:pre-wrap;overflow-wrap:anywhere}button,a{font:inherit}button{padding:10px 18px;margin:8px 8px 0 0}small{color:#526071}.error{color:#982626}</style></head><body>",
      "<main data-test=\"desktop-setup\" data-stage=\"prerequisites\"><h1>Set up this machine</h1>",
      body,
      "</main></body></html>"
    ])
  end

  defp content(%{phase: :ready}, _path, app_url) do
    [
      "<section><h2>CodeMySpec is ready</h2><a data-test=\"open-application\" href=\"",
      escape(app_url),
      "\">Continue to CodeMySpec</a></section>"
    ]
  end

  defp content(status, path, _app_url) do
    [
      "<p>Check the prerequisites, follow any installation guidance, then continue.</p>",
      "<section data-test=\"setup-agent-unavailable\"><h2>Manual setup is available</h2><p>The main agent needs the local database. Until it starts, use the guidance below and run the checks again after installing missing prerequisites.</p></section>",
      error(status.error),
      snapshot(status.snapshot),
      controls(status, path)
    ]
  end

  defp snapshot(nil), do: "<p>No prerequisite checks have run yet.</p>"

  defp snapshot(snapshot) do
    [
      Enum.map(snapshot["steps"], &step/1),
      "<p data-test=\"setup-results-file\" data-path=\"",
      escape(snapshot["results_path"]),
      "\">Results saved to <code>",
      escape(snapshot["results_path"]),
      "</code></p>"
    ]
  end

  defp step(step) do
    [
      "<section data-test=\"prerequisite\" data-name=\"",
      escape(step["key"]),
      "\" data-state=\"",
      escape(step["state"]),
      "\"><h2>",
      escape(step["key"]),
      " — ",
      escape(step["state"]),
      "</h2>",
      Enum.map(step["commands"], fn command ->
        [
          "<pre>",
          escape(Enum.join([command["command"] | command["args"]], " ")),
          "\n",
          escape(command["output"]),
          "</pre>"
        ]
      end),
      error(step["error"]),
      guidance(step),
      "<small>Last attempt: ",
      escape(step["finished_at"] || step["started_at"] || "Not run"),
      "</small></section>"
    ]
  end

  defp guidance(%{"state" => "errored", "key" => key}) do
    ["<p data-test=\"install-instructions\">", escape(instructions(key)), "</p>"]
  end

  defp guidance(_step), do: []

  defp instructions("postgres"),
    do:
      "Install PostgreSQL and its command-line tools, start the service, and make psql available on PATH. Use the installer for your operating system at postgresql.org/download."

  defp instructions("pgvector"),
    do:
      "Install pgvector for the PostgreSQL server you use. On macOS with Homebrew: brew install pgvector. On Debian or Ubuntu, install postgresql-<major-version>-pgvector for your server version. Windows installation instructions are at github.com/pgvector/pgvector. Confirm that psql can connect to the postgres database."

  defp instructions("version_manager"),
    do: "Install mise or asdf and configure both Erlang and Elixir for this machine."

  defp instructions("erlang"),
    do: "Install Erlang through mise or asdf and make erl available on PATH."

  defp instructions("elixir"),
    do: "Install Elixir through mise or asdf and make elixir available on PATH."

  defp instructions("cms"), do: "Install the CodeMySpec CLI and make cms available on PATH."
  defp instructions("vibium"), do: "Install Vibium and make vibium available on PATH."

  defp controls(%{phase: phase}, _path) when phase in [:checking, :starting],
    do: "<p role=\"status\">Working… This page will update automatically.</p>"

  defp controls(status, path) do
    [
      form(path <> "/check", "check-prerequisites", "Check prerequisites"),
      continue_control(Setup.prerequisites_passed?(status.snapshot), path)
    ]
  end

  defp continue_control(true, path),
    do: form(path <> "/continue", "start-application", "Start CodeMySpec")

  defp continue_control(false, _path), do: []

  defp form(path, test, label) do
    [
      "<form method=\"post\" action=\"",
      escape(path),
      "\"><button data-test=\"",
      test,
      "\" type=\"submit\">",
      label,
      "</button></form>"
    ]
  end

  defp error(nil), do: []
  defp error(message), do: ["<pre class=\"error\" role=\"alert\">", escape(message), "</pre>"]

  defp refresh(phase) when phase in [:checking, :starting],
    do: "<meta http-equiv=\"refresh\" content=\"1\">"

  defp refresh(_phase), do: []

  defp escape(value),
    do: value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
