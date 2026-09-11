defmodule CodeMySpec.McpServers.Promotion.Responses do
  @moduledoc """
  How a promotion's outcome reads.

  Shared by both doors — `Promote` (async, for an Alloy agent) and
  `PromoteSync` (blocking, for an external MCP caller) — so the two cannot
  drift into describing the same result differently.
  """

  alias Anubis.Server.Response

  @spec respond({:ok, map()} | {:error, map()}) :: Response.t()
  def respond({:ok, report}), do: Response.tool() |> Response.text(promoted(report))
  def respond({:error, refusal}), do: Response.tool() |> Response.error(refused(refusal))

  @spec started() :: String.t()
  def started do
    """
    Promotion started.

    Gating, merging and restarting takes a while — the analyzer sweep is the
    slow part — so this returns now and the outcome will arrive as a message.
    Carry on with something else; you will be told either way.
    """
    |> String.trim()
  end

  @spec no_project() :: String.t()
  def no_project do
    "No project on this connection, so there is no running dev copy to promote " <>
      "to. Onboard this checkout first."
  end

  @spec no_agent() :: String.t()
  def no_agent do
    "This connection is not an agent, so there is nowhere to send the result. " <>
      "Use promote_sync, which waits and answers."
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
