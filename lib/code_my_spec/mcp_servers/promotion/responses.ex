defmodule CodeMySpec.McpServers.Promotion.Responses do
  @moduledoc """
  How a promotion's outcome reads.

  Shared by all three doors — `Promote` (async, for an Alloy agent),
  `PromoteSync` (blocking, for an external MCP caller) and
  `CmsHarness.Web.PromotionController` (the HTTP wait URL, for a caller whose
  transport must not cap the wait) — so they cannot drift into describing the
  same result differently.
  """

  alias Anubis.Server.Response

  @spec respond({:ok, map()} | {:error, map()}) :: Response.t()
  def respond({:ok, _report} = result), do: Response.tool() |> Response.text(text(result))
  def respond({:error, _refusal} = result), do: Response.tool() |> Response.error(text(result))

  @doc """
  The same words `respond/1` puts in an MCP reply, as plain text.

  The HTTP door needs them without the Anubis envelope: it answers a `curl`,
  and the body it writes is this string plus a status footer. Exposed here
  rather than rendered again over there because a third wording of "what
  happened to your promotion" is a third thing to keep in step — and the whole
  reason this module exists is that two already were.

  Refusal or success, because the door does not get to pick: the footer says
  which, the same way `AnalysisController` reports a failing suite.
  """
  @spec text({:ok, map()} | {:error, map()}) :: String.t()
  def text({:ok, report}), do: promoted(report)
  def text({:error, refusal}), do: refused(refusal)

  @doc """
  What a caller is told the moment a promotion is handed off.

  Names the blocking door as well, the way `start_analysis` does. An Alloy agent
  is messaged when the promotion lands and needs nothing else; every other
  caller has nowhere to be messaged, and telling it only "you will be told" is a
  promise this tool cannot keep for it.

  The URL matters more than it looks. Without it the honest instruction was "use
  promote_sync", which waits for a gate, a merge, an analyzer sweep and a
  restart over a transport that gives up after thirty seconds — so the caller
  that could not be messaged was sent to the one tool guaranteed to fail it, and
  a promotion that had already merged and restarted came back as a timeout
  (88247a09).
  """
  @spec started(Ecto.UUID.t() | nil) :: String.t()
  def started(working_copy_id) do
    """
    Promotion started.

    Gating, merging and restarting takes a while — the analyzer sweep is the
    slow part — so this returns now rather than holding the call open.

    If you are an agent, the outcome arrives as a message and there is nothing
    to do but carry on. If you are not, it is written to the log either way, and
    #{wait_line(working_copy_id)}

    Do not call this again to find out whether it worked. A second promotion
    restarts the shared dev server that every other working copy on this machine
    is using.
    """
    |> String.trim()
  end

  # No working copy on the scope is not worth a second shape of this message —
  # the caller still knows its own harness id, which is what the URL wants.
  defp wait_line(nil),
    do:
      "POST /api/harnesses/<your working copy id>/promotion/run blocks for the\n" <>
        "whole thing with no timeout."

  defp wait_line(working_copy_id),
    do:
      "this blocks for the whole thing with no timeout:\n\n" <>
        "    curl -sX POST localhost:4004/api/harnesses/#{working_copy_id}/promotion/run"

  @spec no_project() :: String.t()
  def no_project do
    "No project on this connection, so there is no running dev copy to promote " <>
      "to. Onboard this checkout first."
  end

  # A promotion from the running copy itself, which is a restart and nothing
  # else. Worded as what happened rather than as a promotion with an empty
  # merge, because an agent reading "Promoted  to the running dev copy" would
  # reasonably conclude something had crossed.
  defp promoted(%{restarted: root, serving: serving}) do
    """
    Restarted the application on the running dev copy.

    Running from: #{root}
    #{serving_line(serving)}

    You are working on the running copy, so nothing had to be merged — the work
    was already where a promotion would put it. What was missing was a running
    application, and it is answering now.
    """
    |> String.trim()
  end

  defp promoted(%{merged: branch, into: root, serving: serving} = report) do
    """
    Promoted #{branch} to the running dev copy.

    Merged into: #{root}
    #{serving_line(serving)}#{swept_line(report)}#{untracked_line(report)}

    The application is running this work now, so QA on these stories will test
    what you wrote.
    """
    |> String.trim()
  end

  defp serving_line(%{revision: nil}), do: "Serving: restarted (revision unavailable)"
  defp serving_line(%{revision: revision}), do: "Serving: #{revision}"

  # Named because a promotion that swept is slower for a reason, and an agent
  # watching it sit should know the gate was waiting on a fresh answer rather
  # than hung.
  # Named, not refused. An untracked file may be a source file nobody added, and
  # a promotion that omitted it would put QA in front of an application missing
  # the work it came to verify. Blocking on it would contradict the gate, which
  # measures dirt with `--untracked-files=no` and sent the agent here.
  defp untracked_line(%{untracked: []}), do: ""

  defp untracked_line(%{untracked: files}) do
    "\n\nNot promoted, because git is not tracking them — if any of these is " <>
      "work you meant to ship, add and commit it, then promote again:\n" <>
      Enum.map_join(files, "\n", &("  " <> &1))
  end

  defp untracked_line(_), do: ""

  defp swept_line(%{swept: []}), do: ""
  defp swept_line(%{swept: swept}), do: "\nSwept before gating: " <> Enum.join(swept, ", ")
  defp swept_line(_), do: ""

  defp refused(%{reason: reason}), do: reason
  defp refused(other), do: inspect(other)
end
