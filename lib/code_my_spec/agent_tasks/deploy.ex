defmodule CodeMySpec.AgentTasks.Deploy do
  @moduledoc """
  Deploy a story's build through the loop (Story 858).

  Once `devops_setup` is complete, deploys ride the ongoing loop: a story
  that clears QA gets promoted — UAT first, health-verified, then prod
  (unless the project opted out of prod). The completion record is
  `.code_my_spec/devops/deploys/story_<id>.md`.
  """

  alias CodeMySpec.Configurations
  alias CodeMySpec.Environments
  alias CodeMySpec.Paths
  alias CodeMySpec.Users.Scope

  @doc """
  One-line description surfaced by the requirement graph when this task is
  the next thing to do.
  """
  def dispatch(_node) do
    "Deploy the story's build: UAT first, verify its health check, then " <>
      "promote to prod. Use when the story has cleared QA and DevOps setup " <>
      "is complete."
  end

  @doc """
  Generate the prompt for the deploy session.
  """
  @spec command(Scope.t(), map()) :: {:ok, String.t()}
  def command(%Scope{} = scope, task) do
    config = Configurations.get_or_create(scope)
    # :off never reaches this task (the graph filter drops the requirement).
    prod? = (Map.get(config, :devops) || :prod) != :uat
    story_id = story_id_of(task)

    {:ok,
     """
     # Deploy Session#{if story_id, do: " — story #{story_id}", else: ""}

     The story has cleared QA — promote the build through the environments.

     ## Order of operations

     1. Build and deploy the current build to **UAT** (`kamal deploy` with
        the UAT config).
     2. **Verify UAT's health check**: request `https://uat.<domain>/health`
        and confirm 200 over valid TLS.
     #{promotion_step(prod?)}

     ## On a failing UAT health check — halt

     If UAT's health check does not pass, **halt the promotion — do not
     deploy prod**. Surface the failure as a problem (create an issue with
     the health-check output) so the loop and the user see it, then stop.
     A sick UAT is a red light, never a warning.

     ## Done signal

     Write `#{deploy_record_path(story_id)}` recording the version deployed,
     each environment's verified health check, and the timestamps. Then call
     `evaluate_task`.
     """}
  end

  @doc """
  Evaluate: the story's deploy record exists.

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
         "No deploy record at `#{record}` — the deploy is complete only when each " <>
           "environment's health check is verified and recorded there."}
    end
  end

  defp promotion_step(true) do
    "3. Only after UAT verifies, deploy **prod** and verify its health\n" <>
      "        check the same way."
  end

  defp promotion_step(false) do
    "3. This project has opted out of the second environment — UAT's\n" <>
      "        verification completes the promotion."
  end

  defp deploy_record_path(nil), do: Path.join(Paths.devops_deploys_dir(), "story_<id>.md")
  defp deploy_record_path(story_id), do: Paths.devops_deploy_record(story_id)

  defp story_id_of(%{story_id: id}) when not is_nil(id), do: id
  defp story_id_of(%CodeMySpec.Stories.Story{id: id}), do: id
  defp story_id_of(entity) when is_map(entity), do: Map.get(entity, :entity_id)
end
