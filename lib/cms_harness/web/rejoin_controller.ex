defmodule CmsHarness.Web.RejoinController do
  @moduledoc """
  Take one working copy's channel down and up again.

  The reconnect a harness restart performs, for one root instead of all of them.
  One harness process serves every checkout on the machine, so until now seeing
  a reconnect meant killing four other projects' in-flight work — which is why
  `0fb7bf03` records five QA passes in a row declining to observe the
  `agents_to_restore` handshake, the thing story 1014's criteria 3304 and 3305
  are entirely about. `handle_join/3` is the only place that handshake runs.

  Not a test-only door. An operator whose copy has stopped reporting has had
  exactly one remedy, and the restart notice says what it costs: "in-flight
  analysis for every working copy dies with it". This is the same act at the
  grain the problem usually has.

  Addressed by harness id, like promotion and analysis, and for the same reason:
  the copy is named in the URL rather than inferred from a directory, so a
  worktree, a sprite and another laptop stay distinguishable.

  ## What it costs, said plainly

  This copy's own analyzers die with its supervisor. Its next stop re-enqueues
  them. Nothing else on the machine is touched, and that is the whole point.
  """
  use Phoenix.Controller, formats: [:json]

  require Logger

  alias CmsHarness.Projects
  alias CmsHarness.WorkingCopies

  def run(conn, %{"harness_id" => working_copy_id}) do
    case WorkingCopies.root(working_copy_id) do
      {:ok, root} ->
        reply(conn, root, Projects.rejoin(root))

      # The same refusal the hooks and promotion give, for the same reason: a
      # directory is not a working copy's name, and this machine cannot rejoin a
      # copy it does not serve.
      :unknown ->
        fail(conn, 404, "this machine does not serve harness id #{working_copy_id}")

      # 503 rather than 404: the id may be fine and nobody could check.
      {:unreachable, reason} ->
        fail(
          conn,
          503,
          "could not reach the CodeMySpec server to resolve harness id " <>
            "#{working_copy_id}: #{inspect(reason, limit: 5)}"
        )
    end
  end

  defp reply(conn, root, {:ok, _project}) do
    Logger.info("[CmsHarness] rejoined #{root}")

    text(conn, """
    Rejoined #{root}.

    The channel dropped and joined again, so the server has been asked what to
    restore on this copy and nothing else on this machine was touched. This
    copy's own analyzers went with its supervisor; the next stop re-enqueues
    them.
    """)
  end

  defp reply(conn, root, {:error, reason}) do
    Logger.error("[CmsHarness] could not rejoin #{root}: #{inspect(reason)}")

    fail(
      conn,
      502,
      "stopped serving #{root} and could not take it up again: " <>
        "#{inspect(reason, limit: 5)}. The harness is now serving one fewer copy " <>
        "than it was — restart it to recover."
    )
  end

  defp fail(conn, status, message) do
    conn |> put_status(status) |> text(message <> "\n")
  end
end
