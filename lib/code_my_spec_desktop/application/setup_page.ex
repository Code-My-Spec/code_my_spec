defmodule CodeMySpecDesktop.Application.SetupPage do
  @moduledoc "Renders desktop prerequisite setup without sessions or database access."

  alias CmsHarness.Setup

  def render(status, action_path, app_url) do
    body = content(status, action_path, app_url)

    refresh =
      case {status.phase, Map.get(status, :authorization)} do
        {:ready, %{phase: phase}} when phase in [:starting, :pending, :unavailable] ->
          refresh(:starting)

        _ ->
          refresh(status.phase)
      end

    IO.iodata_to_binary([
      "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>CodeMySpec setup</title>",
      refresh,
      "<style>body{font:15px system-ui;max-width:560px;margin:48px auto;padding:0 20px;background:#f8fafc;color:#172033}h1{font-size:22px;margin:0 0 6px}p{margin:6px 0}section{background:white;border:1px solid #d8dee6;border-radius:10px;padding:16px 20px;margin:16px 0}ul.checklist{list-style:none;padding:0;margin:16px 0;background:white;border:1px solid #d8dee6;border-radius:10px}ul.checklist>li{padding:10px 16px;border-top:1px solid #edf0f4}ul.checklist>li:first-child{border-top:0}.mark{display:inline-block;width:1.4em;font-weight:600}[data-state=done] .mark{color:#1f7a3d}[data-state=errored] .mark{color:#b42318}.fix{margin:6px 0 0 1.4em;color:#334155}details{margin:6px 0 0 1.4em;color:#526071;font-size:13px}pre{white-space:pre-wrap;overflow-wrap:anywhere;background:#f1f4f8;padding:8px;border-radius:6px}button,a{font:inherit}button{padding:9px 18px;margin:8px 8px 0 0;border-radius:8px;border:1px solid #c3ccd7;background:white;cursor:pointer}button.primary{background:#172033;color:white;border-color:#172033}small,.muted{color:#64748b;font-size:13px}.error{color:#b42318}form{display:inline}</style></head><body>",
      "<main data-test=\"desktop-setup\" data-stage=\"prerequisites\"><h1>Set up this machine</h1>",
      body,
      "</main></body></html>"
    ])
  end

  defp content(%{phase: :ready} = status, path, app_url) do
    [
      authorization(Map.get(status, :authorization), path),
      "<section><h2>CodeMySpec is ready</h2><a data-test=\"open-application\" href=\"",
      escape(app_url),
      "\">Continue to CodeMySpec</a></section>"
    ]
  end

  defp content(status, path, _app_url) do
    [
      "<p class=\"muted\">CodeMySpec needs these on this machine.</p>",
      error(status.error),
      snapshot(status.snapshot),
      controls(status, path),
      "<p class=\"muted\" data-test=\"setup-agent-unavailable\">The setup agent starts once the database is ready; until then, follow the steps above.</p>"
    ]
  end

  defp authorization(%{phase: :pending} = auth, _path) do
    [
      "<section data-test=\"harness-authorization\"><h2>Connect this harness</h2><p>Open <span>",
      escape(auth.verification_uri),
      "</span> and enter this code:</p><code data-test=\"authorization-code\">",
      escape(auth.user_code),
      "</code><p>Waiting for approval…</p></section>"
    ]
  end

  defp authorization(%{phase: :authorized}, _path),
    do: "<section data-test=\"harness-authorized\"><p>This harness is connected.</p></section>"

  defp authorization(%{phase: :stopped}, path) do
    [
      "<section><h2>Harness authorization stopped</h2><p>Start again to request a new approval code.</p>",
      form(path <> "/authorize", "retry-authorization", "Connect this harness"),
      "</section>"
    ]
  end

  defp authorization(_status, _path),
    do: "<p role=\"status\">Preparing harness authorization…</p>"

  defp snapshot(nil), do: []

  defp snapshot(snapshot) do
    [
      "<ul class=\"checklist\">",
      Enum.map(snapshot["steps"], &step/1),
      "</ul><p class=\"muted\" data-test=\"setup-results-file\" data-path=\"",
      escape(snapshot["results_path"]),
      "\">Full results: <code>",
      escape(snapshot["results_path"]),
      "</code></p>"
    ]
  end

  # One line per prerequisite; what was run and what it printed stay folded.
  defp step(step) do
    [
      "<li data-test=\"prerequisite\" data-name=\"",
      escape(step["key"]),
      "\" data-state=\"",
      escape(step["state"]),
      "\"><span class=\"mark\">",
      mark(step["state"]),
      "</span>",
      escape(label(step["key"])),
      guidance(step),
      "<details><summary>Details</summary>",
      Enum.map(step["commands"], fn command ->
        [
          "<pre>$ ",
          escape(Enum.join([command["command"] | command["args"]], " ")),
          "\n",
          escape(command["output"]),
          "</pre>"
        ]
      end),
      error(step["error"]),
      "<small>Last checked: ",
      escape(step["finished_at"] || step["started_at"] || "not yet"),
      "</small></details></li>"
    ]
  end

  defp mark("done"), do: "✓"
  defp mark("errored"), do: "✗"
  defp mark(_running_or_pending), do: "…"

  defp label("postgres"), do: "PostgreSQL"
  defp label("pgvector"), do: "pgvector"
  defp label("version_manager"), do: "mise or asdf"
  defp label("erlang"), do: "Erlang"
  defp label("elixir"), do: "Elixir"
  defp label("cms"), do: "CodeMySpec CLI"
  defp label("vibium"), do: "Vibium"
  defp label(key), do: key

  defp guidance(%{"state" => "errored", "key" => key}) do
    ["<p class=\"fix\" data-test=\"install-instructions\">", escape(instructions(key)), "</p>"]
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
    if Setup.prerequisites_passed?(status.snapshot) do
      [
        form(path <> "/continue", "start-application", "Start CodeMySpec", "primary"),
        form(path <> "/check", "check-prerequisites", "Check again")
      ]
    else
      [form(path <> "/check", "check-prerequisites", check_label(status.snapshot), "primary")]
    end
  end

  defp check_label(nil), do: "Check this machine"
  defp check_label(_snapshot), do: "Check again"

  defp form(path, test, label, class \\ "") do
    [
      "<form method=\"post\" action=\"",
      escape(path),
      "\"><button class=\"",
      class,
      "\" data-test=\"",
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
