defmodule CodeMySpec.MainAgent.Machinery do
  @moduledoc """
  The state of everything the project's agents depend on.

  Story 1057. The question the main agent actually asks when something is wrong
  is "is it the agent or is it the machine", and every part of this struct
  exists to make one half of that answerable.

  ## Faults are attributed, not listed

  `tool_fault` is the discrimination criteria 3310 and 3311 turn on. A fault
  every agent on a machine shares is the machine's and is reported once; a fault
  one agent has while its neighbours work is that agent's and is reported
  against it. A report that listed both would satisfy 3310 and read as four
  problems rather than one, which invites three restarts that each discard work
  to fix nothing.

  ## Every field is populated even when healthy

  Nothing shown and nothing checked look identical, and the main agent guesses
  in the direction that costs — restarting agents. "The main agent can rule it
  out" needs a positive statement, which is why healthy is a value here rather
  than an absence.
  """

  alias CodeMySpec.MainAgent.Machinery

  @type copy :: %{
          working_copy_id: Ecto.UUID.t(),
          root: String.t() | nil,
          connected?: boolean(),
          machine_tools: [String.t()] | nil,
          preview_status: String.t() | nil,
          preview_url: String.t() | nil,
          agent_ids: [Ecto.UUID.t()]
        }

  @type analyzer :: %{
          source: String.t(),
          state: :fresh | :stale | :failed | :never_run,
          finished_at: DateTime.t() | nil
        }

  @type machine :: %{
          hostname: String.t() | nil,
          load: map() | nil,
          load_reported_at: DateTime.t() | nil,
          saturated?: boolean(),
          other_projects: non_neg_integer(),
          agent_ids: [Ecto.UUID.t()]
        }

  @type t :: %__MODULE__{
          copies: [copy()],
          analyzers: [analyzer()],
          machines: [machine()],
          tool_fault: :none | :machine | {:agents, [Ecto.UUID.t()]}
        }

  defstruct copies: [], analyzers: [], machines: [], tool_fault: :none

  @doc """
  Where the inability to call tools belongs.

  `:machine` when every agent on the project is affected — one fault underneath
  them, reported once. `{:agents, ids}` when some are and others are not, which
  places it with the ones that have it. `:none` when nobody is affected.

  The comparison needs the whole fleet, which is why this is decided here rather
  than per copy: a report that read only the asking checkout would see one
  broken machine with nothing to compare it against, and "one agent" and "every
  agent" would be the same reading.
  """
  @spec tool_fault([copy()]) :: :none | :machine | {:agents, [Ecto.UUID.t()]}
  def tool_fault(copies) do
    {toolless, able} = Enum.split_with(copies, &toolless?/1)

    classify(
      Enum.flat_map(toolless, & &1.agent_ids),
      Enum.flat_map(able, & &1.agent_ids)
    )
  end

  defp classify([], _working), do: :none
  defp classify(_affected, []), do: :machine
  defp classify(affected, _working), do: {:agents, affected}

  # `nil` and `[]` are different answers and only one is a fault. Nil is a copy
  # that has not said what it can do — every copy before the field existed, and
  # every one that has not joined since — and calling that broken would report
  # most of the fleet as unable to work.
  defp toolless?(%{machine_tools: [], agent_ids: [_ | _]}), do: true
  defp toolless?(_copy), do: false

  @doc """
  Whether this machine is carrying more than it can.

  A threshold, and it is the one judgement in this module — kept because the
  alternative is handing the main agent two numbers whose relationship is
  platform knowledge it has no way to acquire. The numbers travel beside it, so
  a reader that disagrees can say so, which is the rule criterion 3275 sets for
  everything else here.
  """
  @spec saturated?(map() | nil, non_neg_integer() | nil) :: boolean()
  def saturated?(nil, _cpu_count), do: false

  def saturated?(load, cpu_count) do
    over_committed?(load["load_average"], cpu_count) or short_of_memory?(load["memory_free_mb"])
  end

  # Twice the processor count is the conventional line between busy and
  # struggling, and it is where waiting starts to dominate working.
  defp over_committed?(average, count)
       when is_number(average) and is_number(count) and count > 0,
       do: average > count * 2

  defp over_committed?(_average, _count), do: false

  defp short_of_memory?(free) when is_number(free), do: free < 512
  defp short_of_memory?(_free), do: false

  @doc "Every agent this report covers, for a caller that needs the whole set."
  @spec agent_ids(t()) :: [Ecto.UUID.t()]
  def agent_ids(%Machinery{copies: copies}), do: Enum.flat_map(copies, & &1.agent_ids)

  @doc """
  The agents running on one machine.

  Per machine and not the whole fleet, which is the point of showing them at
  all: criterion 3324 asks that slow agents be readable *against* the box they
  are on, and a list repeated identically under every box answers a question
  nobody asked. Worse, it puts a saturated machine's agents under a healthy one
  as well, which is the attribution error this whole story is about.
  """
  @spec agents_on(t(), Ecto.UUID.t() | nil) :: [Ecto.UUID.t()]
  def agents_on(%Machinery{copies: copies}, device_id) do
    copies
    |> Enum.filter(&(Map.get(&1, :device_id) == device_id))
    |> Enum.flat_map(& &1.agent_ids)
  end
end
