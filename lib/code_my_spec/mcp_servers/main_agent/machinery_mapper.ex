defmodule CodeMySpec.McpServers.MainAgent.MachineryMapper do
  @moduledoc """
  How the machinery report is written out.

  ## Healthy is stated, not left out

  Every section appears whether or not anything is wrong with it. Nothing shown
  and nothing checked read identically, and the main agent then guesses in the
  direction that costs — restarting agents to clear a fault that is not there.
  "The main agent can rule it out" is criterion 3309, and ruling something out
  needs a positive statement.

  ## One fault is written once

  Criterion 3310. When every agent on the project cannot call tools, the tools
  line says so and the agents are not listed — naming both reads as four
  problems rather than one and invites the remedy for the wrong one. When only
  some are affected, the same line names them, which is 3311.
  """

  alias Anubis.Server.Response
  alias CodeMySpec.MainAgent.Machinery

  @doc "The whole report."
  @spec report(Machinery.t()) :: Response.t()
  def report(%Machinery{} = machinery) do
    Response.tool()
    |> Response.text(
      Enum.join(
        [
          harnesses(machinery),
          tools(machinery),
          previews(machinery),
          analyzers(machinery),
          machines(machinery)
        ],
        "\n"
      )
    )
  end

  @spec error(term()) :: Response.t()
  def error(reason) do
    Response.tool() |> Response.error("Could not read the machinery: #{inspect(reason)}")
  end

  defp harnesses(%Machinery{copies: []}) do
    "harness: no checkouts have joined this project yet.\n"
  end

  defp harnesses(%Machinery{copies: copies}) do
    {connected, absent} = Enum.split_with(copies, & &1.connected?)

    """
    harness: #{length(connected)} of #{length(copies)} checkout(s) connected#{gone(absent)}
    #{Enum.map_join(copies, "\n", &harness_line/1)}
    """
  end

  defp harness_line(copy) do
    "  #{copy.working_copy_id} #{copy.root} — #{connection(copy.connected?)}"
  end

  defp connection(true), do: "connected"
  defp connection(false), do: "not connected"

  defp gone([]), do: " — all working"
  defp gone(absent), do: " — #{length(absent)} not answering"

  defp tools(%Machinery{tool_fault: :none}) do
    "tools: working — every agent's machine is answering with a usable tool list.\n"
  end

  # Reported once, against the thing that is wrong, and the agents deliberately
  # not named: they are not what is broken.
  defp tools(%Machinery{tool_fault: :machine, copies: copies}) do
    """
    tools: FAULTY on the machinery — every agent on this project is on a machine
      reporting no tools, so every tool call any of them makes will fail. This is
      one fault underneath them and not #{length(Enum.flat_map(copies, & &1.agent_ids))} separate agent faults.
      Restarting agents will not reach it; they come back into the same client.
    """
  end

  defp tools(%Machinery{tool_fault: {:agents, ids}}) do
    """
    tools: the machinery is working — other agents on this project are calling
      tools normally. These are not:
    #{Enum.map_join(ids, "\n", &"      #{&1}")}
      The fault is theirs rather than the machine's.
    """
  end

  defp previews(%Machinery{copies: copies}) do
    "preview:\n" <> Enum.map_join(copies, "\n", &preview_line/1) <> "\n"
  end

  defp preview_line(%{preview_status: nil} = copy),
    do: "  #{copy.root} — none reported"

  defp preview_line(copy),
    do: "  #{copy.root} — #{copy.preview_status}#{at(copy.preview_url)}"

  defp at(nil), do: ""
  defp at(url), do: " at #{url}"

  defp analyzers(%Machinery{analyzers: analyzers}) do
    "analyzers:\n" <> Enum.map_join(analyzers, "\n", &analyzer_line/1) <> "\n"
  end

  # A stale run's numbers are deliberately absent. Flagging the staleness while
  # still quoting them is a warning nobody reads beside an outcome nobody
  # questions — the result is not a weaker answer, it is an answer to a
  # different question.
  defp analyzer_line(%{source: source, state: :fresh}),
    do: "  #{source} — working, and its result is about the code that is here now"

  defp analyzer_line(%{source: source, state: :stale}),
    do:
      "  #{source} — STALE: it last completed against different files, so whatever " <>
        "it said is not a verdict on this code. Nothing it reports should be read as passing."

  defp analyzer_line(%{source: source, state: :failed}),
    do: "  #{source} — FAILED: its last run did not finish, so this gate cannot be answered"

  defp analyzer_line(%{source: source, state: :never_run}),
    do: "  #{source} — has not run here"

  defp machines(%Machinery{machines: []}), do: "machine: nothing has reported a device.\n"

  defp machines(%Machinery{machines: machines}) do
    "machine:\n" <> Enum.map_join(machines, "\n", &machine_line/1) <> "\n"
  end

  defp machine_line(machine) do
    """
      #{machine.hostname} — #{load(machine)}
        #{tenancy(machine.other_projects)}
        agents on it: #{agents_on(machine)}\
    """
  end

  defp load(%{load: nil}), do: "has not reported what it is carrying"

  defp load(%{saturated?: true} = machine) do
    "SATURATED: #{figures(machine.load)}. Agents here will be slow or appear " <>
      "stalled for that reason; restarting them adds to what it is carrying."
  end

  defp load(%{load: load}), do: "load is fine: #{figures(load)}"

  defp figures(load) do
    load
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join(", ", fn {key, value} -> "#{key}=#{value}" end)
  end

  # A count and nothing else. It is the smallest fact that answers "am I alone
  # on this machine", which is what makes a shared fault legible — and it names
  # nobody, because seeing the machinery is not seeing other people's work.
  defp tenancy(0), do: "this project is the only one on it"

  defp tenancy(count),
    do:
      "shared: #{count} other project(s) have checkouts here, so anything done to " <>
        "this machine takes their in-flight work with it"

  # This machine's agents, not the fleet's. A list repeated under every box
  # answers a question nobody asked, and puts a saturated machine's agents under
  # a healthy one — the attribution error this whole story is about.
  defp agents_on(%{agent_ids: []}), do: "none"
  defp agents_on(%{agent_ids: ids}), do: Enum.join(ids, ", ")
end
