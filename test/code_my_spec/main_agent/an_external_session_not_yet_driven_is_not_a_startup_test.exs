defmodule CodeMySpec.Agents.Main.AnExternalSessionNotYetDrivenIsNotAStartupTest do
  @moduledoc """
  A person's own Claude Code or Codex session reads `:starting` until it is
  driven, since no harness launches it. Main's check-in named every one as
  "starting; inspect startup progress" on every check-in, all day. Only an
  agent a harness launches is a startup to watch.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Agents.Main.{AgentWork, CheckInReport, Digest, Machinery}

  defp digest(entry),
    do: %Digest{questions: [], machinery: %Machinery{tool_fault: :none}, work: [entry]}

  defp starting(external?) do
    %AgentWork{
      agent_id: Ecto.UUID.generate(),
      role: :coding,
      agent_status: :starting,
      external?: external?,
      machine_tools: ["promote"],
      idle?: true
    }
  end

  test "an external session not yet driven does not need main" do
    digest = digest(starting(true))

    refute CheckInReport.needs_attention?(digest)
    refute CheckInReport.render(digest) =~ "inspect startup progress"
  end

  test "an agent the harness is starting still does" do
    digest = digest(starting(false))

    assert CheckInReport.needs_attention?(digest)
    assert CheckInReport.render(digest) =~ "starting; inspect startup progress"
  end
end
