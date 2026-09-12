defmodule CodeMySpecSpex.Story1065.Criterion3383Spex do
  @moduledoc """
  Story 1065 — Every process an agent is expected to follow is written down
  Criterion 3383 — A playbook hands off rather than restating.

  The rule:

  > A playbook that assumes the process points at where the process is written.

  ## What this spec asserts, and what it cannot

  The criterion has two halves and only one of them is checkable.

  **Points at where it is written** — checkable. A playbook either references
  the process document or it does not, and a reference is a string.

  **Rather than restating it in its own words** — not checkable. Whether prose
  restates or refers is a judgement about meaning, and no assertion makes it.
  A spec that claimed to check it would be checking something else and saying
  it had checked this.

  So this asserts the first half honestly and leaves the second to review. That
  is a narrowing of the criterion and it is recorded here rather than hidden:
  a green bar on this file does not mean playbooks have stopped restating.

  ## Why `three_amigos/workflow.md`

  It is the playbook that leans hardest on the surrounding process. It tells an
  agent that sealing is one-way and satisfies `three_amigos_complete`, without
  saying what makes a story visible in the first place or that `evaluate_task`
  needs a task id from `start_task`. An agent reading it on 2026-09-12 sealed
  two stories and could not seal a third, because the missing half was never
  pointed at.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Knowledge.Tools.ReadKnowledge

  setup :register_log_in_setup_account
  setup :setup_active_project

  @playbook "three_amigos/workflow.md"
  @process "process/product.md"

  spex "A playbook hands off rather than restating" do
    scenario "a playbook that assumes the process is read" do
      given_ "an agent reading a task playbook that assumes the process around it", context do
        {:ok, context}
      end

      when_ "it reaches something the process decides", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = ReadKnowledge.execute(%{path: @playbook}, frame)

        {:ok, context |> Map.put(:response, response) |> Map.put(:text, response_text(response))}
      end

      then_ "the playbook points at where that is written", context do
        refute context.response.isError,
               "#{@playbook} could not be read, so the premise of this criterion — a " <>
                 "playbook that assumes a process — does not hold. Got:\n#{context.text}"

        assert context.text =~ ~r/#{Regex.escape(@process)}|process\//,
               "#{@playbook} assumes the process around it — sealing, what it satisfies, " <>
                 "what a story needs before any of it applies — and points at none of " <>
                 "it. An agent that reads only this playbook seals a story and then " <>
                 "cannot work out why nobody is offered it."

        {:ok, context}
      end
    end
  end
end
