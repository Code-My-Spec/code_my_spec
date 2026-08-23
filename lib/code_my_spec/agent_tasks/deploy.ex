defmodule CodeMySpec.AgentTasks.Deploy do
  @moduledoc """
  Release a story's build to UAT (Stories 858/859).

  Once `devops_setup` is complete, every story that clears QA is released
  to UAT immediately — health-verified, recorded as a `deploys` row
  (`CodeMySpec.Deploys`). Prod promotion does NOT happen here: it belongs
  to the formal release process (`AgentTasks.Release`), which runs at the
  end of the cycle after the user journeys are complete.
  """

  alias CodeMySpec.Deploys
  alias CodeMySpec.Users.Scope

  @doc """
  One-line description surfaced by the requirement graph when this task is
  the next thing to do.
  """
  def dispatch(_node) do
    "Release the story's build to UAT and verify its health check — prod " <>
      "promotion belongs to the cycle-end release process. Use when the " <>
      "story has cleared QA and DevOps setup is complete."
  end

  @doc """
  Generate the prompt for the UAT deploy session.
  """
  @spec command(Scope.t(), map()) :: {:ok, String.t()}
  def command(%Scope{} = _scope, task) do
    story_id = story_id_of(task)

    {:ok,
     """
     # UAT Deploy Session#{if story_id, do: " — story #{story_id}", else: ""}

     The story has cleared QA — release the build to UAT. Prod is NOT part
     of this session: prod promotion happens in the cycle-end release
     process, after the user journeys are complete.

     ## Procedure

     1. Run the project's deploy step for **UAT** (`run_devops_setup`, or
        the equivalent devops routine invocation) — the same step that
        already records the deploy. It writes the `deploys` row itself,
        automatically, and only after UAT's health check passes.

     ## On a failing UAT health check — halt

     If UAT's health check does not pass, **halt** — the deploy is not done.
     Surface the failure as a problem (create an issue with the health-check
     output) so the loop and the user see it, then stop. A sick UAT never
     reads as shipped.

     ## Done signal

     Call `evaluate_task`. It reads the `deploys` row directly — there is
     nothing to write by hand. If it still reports invalid, the deploy has
     not health-verified yet; re-run the deploy step rather than recording
     anything yourself. This row is what the release process later compiles
     into the prod release notes.
     """}
  end

  @doc """
  Evaluate: the story is deployed to UAT and health-verified.

  Called two ways: as the requirement's delegate check (second arg is the
  Story struct) and as the task evaluator (second arg is the task, which
  carries `story_id`/`entity_id`). Normalize both. Reads the same `deploys`
  row the requirement graph's own `check_type: :deployed` check reads, so
  the two paths cannot disagree about whether a deploy counts.
  """
  @spec evaluate(Scope.t(), map() | struct()) :: {:ok, :valid} | {:ok, :invalid, String.t()}
  def evaluate(%Scope{} = scope, entity) do
    case story_id_of(entity) do
      nil ->
        {:ok, :invalid, "No story to check — the deploy task needs a story_id."}

      story_id ->
        if Deploys.deployed?(scope, story_id, "uat") do
          {:ok, :valid}
        else
          {:ok, :invalid,
           "Story #{story_id} has no health-verified UAT deploy yet. Run the deploy " <>
             "step — it records the `deploys` row itself once the health check passes."}
        end
    end
  end

  defp story_id_of(%{story_id: id}) when not is_nil(id), do: id
  defp story_id_of(%CodeMySpec.Stories.Story{id: id}), do: id
  defp story_id_of(entity) when is_map(entity), do: Map.get(entity, :entity_id)
end
