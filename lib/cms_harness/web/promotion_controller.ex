defmodule CmsHarness.Web.PromotionController do
  @moduledoc """
  Promotion's external door: a URL that blocks until the promotion is done.

  There are two shapes of promote and they differ only in how the outcome gets
  back. `Promotion.promote_async/2` is the internal one — an Alloy agent has a
  conversation, so the tool call returns at once and the result arrives as a
  message. A caller reaching in from outside has nowhere to be messaged, so it
  has to wait, and this is where the waiting happens.

  It is HTTP rather than an MCP tool for the reason `AnalysisController.wait/2`
  already documents, measured rather than theoretical: MCP's transport caps a
  request at 30s. A promotion gates on an analyzer sweep, merges, and runs `just
  restart` — which compiles, migrates and polls for the application — so on a
  cold tree it is minutes, and `promote_sync` is a blocking MCP tool for exactly
  the workload the cap refuses. Nothing caps this. Bandit does not time out
  long-running handlers.

  Addressed by harness id, like the hooks and like analysis, and for the same
  reason: the working copy is named in the URL rather than inferred from a
  directory, so a worktree, a sprite and another laptop are all distinguishable.

  The promotion itself does not run here. `Promotion.gate/1` and
  `gate_target/3` read the database and this machine has none, so the request
  goes down the project channel and the server orchestrates — sending the disk
  half back as the three named `fs_request` ops `ChannelClient` already
  implements. That split is `Promotion.Runner`'s whole design, and this adds no
  second way to run anything.

  The body is the promotion's own report with a status footer, in the shape
  `AnalysisController` established. `curl` exits 0 whether or not the gate
  refused, so the footer is how a caller tells a promotion from a refusal.
  """
  use Phoenix.Controller, formats: [:json]

  require Logger

  alias CmsHarness.Project.ChannelClient
  alias CmsHarness.WorkingCopies

  @doc """
  Promote this working copy and answer with what happened.

  Blocks for the length of the promotion. Fire it in the background and be
  notified when it returns, the same way `analysis/wait` is used.
  """
  def run(conn, %{"harness_id" => working_copy_id}) do
    case WorkingCopies.root(working_copy_id) do
      {:ok, root} ->
        Logger.info("[CmsHarness] promoting #{root}")
        reply(conn, ChannelClient.await_promotion(root))

      # Nothing to fall back to: this harness does not serve that working copy,
      # so it cannot promote it and must not pretend the promotion happened.
      # The same refusal the hooks give, for the same reason — a directory is
      # not a working copy's name.
      :unknown ->
        fail(conn, 404, "this machine does not serve harness id #{working_copy_id}")

      # 503, not 404: the id may be fine and nobody could check. A 404 tells the
      # caller their id is wrong, which is the same wrong turn the hook refusal
      # used to take when `:4000` was down.
      {:unreachable, reason} ->
        fail(
          conn,
          503,
          "could not reach the CodeMySpec server to resolve harness id " <>
            "#{working_copy_id}: #{inspect(reason, limit: 5)}"
        )
    end
  end

  # A refusal is an outcome, not a failure of this endpoint. The gate declining,
  # a conflict, uncommitted work — each is the promotion working correctly and
  # naming what the caller has to act on, so it answers 200 with the refusal in
  # the body and a non-zero exit status in the footer. Exactly how a failing
  # suite comes back from `analysis/run`.
  defp reply(conn, {:ok, %{"status" => status, "report" => report}}) do
    text(conn, """
    #{report}

    ── promotion: #{status} ──
    exit status: #{if status == "promoted", do: 0, else: 1}
    """)
  end

  # The promotion may have happened and this cannot read the answer. Not
  # reported as a success — an empty body with exit 0 is exactly what a clean
  # promotion looks like, and a caller acting on that would send QA at code
  # that never crossed.
  defp reply(conn, {:ok, other}),
    do: fail(conn, 502, "unreadable promotion reply: #{inspect(other)}")

  defp reply(conn, {:error, reason}),
    do: fail(conn, 502, "could not promote: #{inspect(reason)}")

  # Non-zero in the footer as well as in the HTTP status. The agent reads the
  # body; a wrapper reads the code; neither should have to consult the other.
  defp fail(conn, status, message) do
    conn
    |> put_status(status)
    |> text("""
    #{message}

    ── promotion: not attempted ──
    exit status: 1
    """)
  end
end
