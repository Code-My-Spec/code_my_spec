defmodule CmsHarness.Web.AnalysisController do
  @moduledoc """
  The agent's own `mix test` / `mix spex`, rewritten here by the PreToolUse hook.

  Why route it at all: a bare shell `mix test` produces no run record, so the
  stop hook a minute later sees no evidence the suite ran and runs it again.
  That was 118 seconds of exunit immediately after the agent had finished the
  identical suite, every turn. Routed, the run has a ledger row, a concurrent
  identical request joins it rather than contending for `_build`, and its
  Problems reconcile centrally.

  Addressed by harness id, like the hooks, and for the same reason: the working
  copy is named in the URL rather than inferred from a directory, so a worktree,
  a sprite and another laptop are all distinguishable.

  The body is the tool's own output with a status footer. `curl` exits 0 whether
  or not tests failed, so the footer is how the agent tells pass from fail —
  identical in shape to `CodeMySpecLocalWeb.AnalysisController`, because from
  the agent's side these must be indistinguishable.
  """
  use Phoenix.Controller, formats: [:json]

  require Logger

  alias CmsHarness.Project.ChannelClient
  alias CmsHarness.WorkingCopies

  @valid_sources ~w(compiler credo exunit spex)

  def run(conn, %{"harness_id" => harness_id} = params) do
    source = Map.get(params, "source")
    args = Map.get(params, "args", [])

    cond do
      source not in @valid_sources ->
        fail(conn, 422, "unknown analyzer source: #{inspect(source)}")

      not is_list(args) or not Enum.all?(args, &is_binary/1) ->
        fail(conn, 422, "args must be a list of strings")

      true ->
        dispatch(conn, harness_id, source, args)
    end
  end

  defp dispatch(conn, harness_id, source, args) do
    case WorkingCopies.root(harness_id) do
      {:ok, root} ->
        Logger.info("[CmsHarness] agent run: #{source} #{Enum.join(args, " ")}")
        reply(conn, ChannelClient.await_analysis(root, source, args))

      # Nothing to fall back to: this harness does not serve that working copy,
      # so it cannot run the suite and must not pretend the run happened. The
      # same refusal the hooks give, for the same reason — a directory is not a
      # working copy's name.
      :unknown ->
        fail(conn, 404, "this machine does not serve harness id #{harness_id}")
    end
  end

  defp reply(conn, {:ok, %{"output" => output} = run}) do
    text(conn, """
    #{output}

    ── analysis run #{run["run_id"]}: #{run["status"]}, #{stats_line(run)} ──
    exit status: #{exit_status(run)}
    """)
  end

  # The run happened but the reply is not one this knows how to read. Not
  # reported as a passing suite — an empty body with exit 0 is exactly what a
  # clean run looks like.
  defp reply(conn, {:ok, other}) do
    fail(conn, 502, "unreadable analysis reply: #{inspect(other)}")
  end

  defp reply(conn, {:error, reason}) do
    fail(conn, 502, "analysis run failed: #{inspect(reason)}")
  end

  defp stats_line(%{"stats" => stats}) when is_map(stats) and map_size(stats) > 0 do
    Enum.map_join(stats, ", ", fn {k, v} -> "#{k}: #{v}" end)
  end

  defp stats_line(_run), do: "no stats"

  # A run that failed without a tool exit code — a crash, a skip, a timeout —
  # still has to read as failure.
  defp exit_status(%{"exit_status" => status}) when is_integer(status), do: status
  defp exit_status(%{"status" => "completed"}), do: 0
  defp exit_status(_run), do: 1

  # Non-zero in the footer as well as in the HTTP status. The agent reads the
  # body; a wrapper reads the code; neither should have to consult the other.
  defp fail(conn, status, message) do
    conn
    |> put_status(status)
    |> text("""
    #{message}

    ── analysis run: not completed ──
    exit status: 1
    """)
  end
end
