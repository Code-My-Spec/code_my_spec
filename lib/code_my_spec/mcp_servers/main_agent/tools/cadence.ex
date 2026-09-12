defmodule CodeMySpec.McpServers.MainAgent.Tools.Cadence do
  @moduledoc """
  How often you are woken to look in on your agents, and whether you are being
  woken at all.

  Called with no arguments it reports; called with `seconds` it sets the
  interval. Twenty minutes is the starting default and it was a guess — it is
  the one number trading the feature's two costs against each other, and the
  right value is not knowable in advance. Too long and a stalled agent burns
  most of a window before anybody looks; too short and the check-ins cost more
  than they find on a machine that is also running the agents.

  Reports two separate things, because they are separate and conflating them is
  how a broken cadence stayed invisible:

    * **woken** — whether this project is meant to be woken at all, or has stood
      down. A decision, and it survives a restart.
    * **running** — whether a timer actually exists right now. A fact.

  They disagree in exactly the case worth catching: meant to be woken, and
  nothing there to wake it.
  """

  # Exposed because story 1059 is written from the main agent's side — "I want
  # to be woken on a regular cadence" — and an agent that cannot read or set its
  # own interval cannot honour "the interval is set rather than assumed". QA
  # found six of that story's nine criteria had no agent-facing surface at all,
  # so they could only be driven through the in-process Fixtures bridge, which
  # is not a surface.

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.MainAgent
  alias CodeMySpec.McpServers.Validators

  schema do
    field(:seconds, :integer,
      required: false,
      description: "Set the interval to this many seconds. Omit to report without changing it."
    )
  end

  @impl true
  def execute(params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} -> {:reply, apply_and_report(scope, Map.get(params, :seconds)), frame}
      {:error, reason} -> {:reply, refusal(reason), frame}
    end
  end

  defp apply_and_report(scope, nil), do: report(scope)

  defp apply_and_report(scope, seconds) when is_integer(seconds) and seconds > 0 do
    :ok = MainAgent.set_cadence_interval(scope, seconds)
    report(scope)
  end

  # Refused rather than clamped. A zero or negative interval is a request whose
  # only sensible reading is "stop", and `tap_out` already says that — guessing
  # here would give two ways to stop and one of them silent.
  defp apply_and_report(_scope, seconds) do
    Anubis.Server.Response.error(
      Anubis.Server.Response.tool(),
      "An interval has to be a positive number of seconds; got #{inspect(seconds)}. " <>
        "To stop being woken, tap out."
    )
  end

  defp report(scope) do
    Anubis.Server.Response.text(
      Anubis.Server.Response.tool(),
      """
      interval: every #{MainAgent.cadence_interval(scope)}s
      woken: #{woken(MainAgent.cadence_running?(scope))}
      running: #{running(MainAgent.cadence_alive?(scope))}
      """
    )
  end

  defp woken(true), do: "yes — this project has not stood down"
  defp woken(false), do: "no — this project has stood down; it is still reachable by question"

  defp running(true), do: "yes — a timer exists"

  defp running(false),
    do: "no — nothing is scheduled to wake you, so a silent agent will not be noticed"

  defp refusal(reason) do
    Anubis.Server.Response.error(
      Anubis.Server.Response.tool(),
      "Could not read this project's cadence: #{inspect(reason)}"
    )
  end
end
