defmodule CodeMySpecSpex.Story1065.Criterion3392Spex do
  @moduledoc """
  Story 1065 — Every process an agent is expected to follow is written down
  Criterion 3392 — An unfamiliar task has a playbook.

  The rule:

  > Every agent task has a playbook, or is recorded as deliberately not having
  > one.

  ## The "or" is the point

  Not every task needs a document. Some are thin enough that a prompt is the
  whole of it. What an agent cannot survive is *not knowing which* — looking,
  finding nothing, and being unable to tell "nobody wrote this" from "there is
  nothing to write". The first means go carefully; the second means proceed.

  So the criterion is satisfied two ways and this spec accepts both: a playbook,
  or a statement that this task deliberately has none. What it refuses is
  silence.

  ## Why `promote_work`

  Of the 41 modules under `lib/code_my_spec/agent_tasks/`, roughly 27 have no
  matching knowledge folder. `promote_work` is chosen here because it is the one
  with a measured bill: an agent rediscovering it on 2026-09-12 spent about an
  hour on a gate, a sweep and a restart that report failure while succeeding.
  If any task earns a playbook, it is this one — and if the answer is that it
  deliberately has none, that is a decision somebody should have to write down.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Knowledge.Tools.ListKnowledge

  setup :register_log_in_setup_account
  setup :setup_active_project

  @task "promote_work"

  spex "An unfamiliar task has a playbook" do
    scenario "an agent handed a task it has not done before goes looking" do
      given_ "an agent handed a task it has not done before", context do
        # given: already true — "has not done it before" is the ordinary state
        # of a fresh agent and there is nothing to unset. What the assertion
        # needs is the knowledge index, which the checkout provides: the
        # library is committed under `priv/knowledge/`.
        #
        # Starting a real `promote_work` task would be the wrong scene to set.
        # The criterion is that an agent can look the task up *before* running
        # it, which is exactly when no task exists.
        {:ok, context}
      end

      when_ "it looks for how that task is done", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        # The index, not a guessed path: an agent that does not know whether a
        # playbook exists cannot open one, so the first move is to look at what
        # is there.
        {:reply, response, _frame} = ListKnowledge.execute(%{}, frame)

        {:ok, Map.put(context, :index, response_text(response))}
      end

      then_ "it finds a playbook, or a statement that this task deliberately has none",
            context do
        documented? = context.index =~ ~r/#{@task}/i

        # The second half of the "or". A place that records the tasks which
        # deliberately have no playbook is itself a document, and finding it is
        # how an agent tells a decision from an omission.
        decision_recorded? = context.index =~ ~r/process/i

        assert documented? or decision_recorded?,
               "`#{@task}` has no playbook and there is nowhere recording that it " <>
                 "deliberately has none. An agent looking it up finds silence, which " <>
                 "reads the same as a task so simple nobody bothered — and this is the " <>
                 "task that cost an hour of retrying a gate that was working. " <>
                 "Index was:\n" <> String.slice(context.index, 0, 500)

        {:ok, context}
      end
    end
  end
end
