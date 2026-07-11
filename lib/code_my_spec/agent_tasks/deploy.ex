defmodule CodeMySpec.AgentTasks.Deploy do
  @moduledoc """
  Release a story's build to UAT (Stories 858/859).

  Once `devops_setup` is complete, every story that clears QA is released
  to UAT immediately — health-verified, recorded at
  `.code_my_spec/devops/deploys/story_<id>.md`. Prod promotion does NOT
  happen here: it belongs to the formal release process
  (`AgentTasks.Release`), which runs at the end of the cycle after the
  user journeys are complete.
  """

  alias CodeMySpec.Environments
  alias CodeMySpec.Paths
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

     1. Build and deploy the current build to **UAT** (`kamal deploy` with
        the UAT config).
     2. **Verify UAT's health check**: request `https://uat.<domain>/health`
        and confirm 200 over valid TLS.

     ## On a failing UAT health check — halt

     If UAT's health check does not pass, **halt** — the deploy is not done.
     Surface the failure as a problem (create an issue with the health-check
     output) so the loop and the user see it, then stop. A sick UAT never
     reads as shipped.

     ## Done signal

     Write `#{deploy_record_path(story_id)}` recording the version deployed
     and UAT's verified health check with timestamps. Then call
     `evaluate_task`. This record is what the release process later compiles
     into the prod release notes.
     """}
  end

  @doc """
  Evaluate: the story's UAT deploy record exists and attests verification.

  Called two ways: as the requirement's delegate check (second arg is the
  Story struct) and as the task evaluator (second arg is the task, which
  carries `story_id`/`entity_id`). Normalize both.
  """
  @spec evaluate(Scope.t(), map() | struct()) :: {:ok, :valid} | {:ok, :invalid, String.t()}
  def evaluate(%Scope{environment: env}, entity) do
    story_id = story_id_of(entity)
    record = deploy_record_path(story_id)

    case Environments.read_file(env, record) do
      {:ok, content} ->
        if content =~ "verified" do
          {:ok, :valid}
        else
          {:ok, :invalid,
           "Deploy record `#{record}` exists but doesn't attest a verified health check."}
        end

      {:error, _} ->
        {:ok, :invalid,
         "No deploy record at `#{record}` — the UAT deploy is complete only when " <>
           "its health check is verified and recorded there."}
    end
  end

  defp deploy_record_path(nil), do: Path.join(Paths.devops_deploys_dir(), "story_<id>.md")
  defp deploy_record_path(story_id), do: Paths.devops_deploy_record(story_id)

  defp story_id_of(%{story_id: id}) when not is_nil(id), do: id
  defp story_id_of(%CodeMySpec.Stories.Story{id: id}), do: id
  defp story_id_of(entity) when is_map(entity), do: Map.get(entity, :entity_id)
end
