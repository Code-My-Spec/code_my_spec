defmodule CodeMySpec.Requirements.DispatchChecker do
  @moduledoc """
  The node that gets the main agent to keep work moving.

  John: *"the purpose of this is just to have a place in the graph that says
  hey agent, get some work ready to go, until the project is totally
  complete."*

  ## The condition, and why it is not "is everything assigned"

  He started there and corrected himself:

  > "maybe the condition is actually that there is no ongoing work, so none of
  > the working copies are in progress, and there is no unassigned work ... if
  > an agent is working on our story, the main agent doesn't need to assign more
  > work."

  So this is **unsatisfied only when nothing is in progress and unassigned work
  exists** — the one state that wants somebody to act. Anything already being
  built satisfies it, because piling a second epic onto a busy copy is the thing
  act-when-idle exists to prevent.

  ## Why it reports a reason

  The two ways of being satisfied mean opposite things. Nothing in progress and
  nothing left is a finished project; something underway is a working one. A
  node that reported them identically would leave a screen unable to tell a
  project that is done from one that is merely busy, and the timeline in story
  965 reads exactly this to decide what to say.
  """

  alias CodeMySpec.EpicDispatch

  @doc """
  Whether the main agent has nothing to do about assignment.

  Satisfied is the quiet state. Unsatisfied means: prepare the next epic and
  send it for approval — not assign it, because sending and approving are two
  separate acts.
  """
  @spec dispatched?(term(), term()) :: {boolean(), map()}
  def dispatched?(scope, _entity), do: scope |> EpicDispatch.dispatch_state() |> verdict()

  @doc """
  The verdict for a dispatch state the caller already worked out.

  `dispatch_state/1` costs two queries — is any epic dispatched, and which ready
  stories belong to none — and `Requirements.Handlers` has the stories in a
  profile already. A rollup that re-queries on every drain is the thing profiles
  replace; this keeps the wording in one place while the rows come from
  wherever the caller got them.
  """
  @spec verdict(EpicDispatch.dispatch_state()) :: {boolean(), map()}
  def verdict(state) do
    case state do
      {:nothing_to_assign, :in_progress} ->
        {true, %{status: "Work is underway; nothing to assign while an epic is being built"}}

      {:nothing_to_assign, :all_assigned} ->
        {true, %{status: "Every ready story belongs to an epic; nothing left to hand out"}}

      {:work_to_assign, stories} ->
        {false,
         %{
           reason:
             "#{length(stories)} ready #{noun(length(stories))} and nothing being built — " <>
               "group them into an epic and send it for approval"
         }}
    end
  end

  defp noun(1), do: "story"
  defp noun(_), do: "stories"
end
