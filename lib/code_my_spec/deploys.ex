defmodule CodeMySpec.Deploys do
  @moduledoc """
  What has actually been deployed, per story and environment.

  The `deploy` requirement used to read a markdown file the agent wrote and
  check it for the substring "verified", which meant the gated party could
  satisfy the gate by asserting it. That is why it came out of the graph
  (d207ad38). This is the read model that lets it come back: a deploy is
  recorded when one happens, and only a passing health check sets the field the
  requirement reads.

  Scoped to a project throughout — a deploy belongs to the project whose story
  it shipped, and nothing here answers across projects.
  """

  import Ecto.Query

  alias CodeMySpec.Deploys.Deploy
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  @doc """
  Record a deploy, or update the one already there for this story and
  environment.

  Upsert rather than insert: redeploying a story is ordinary, and a row per
  attempt would make "is this story on UAT" a question about the newest of
  several rows instead of a lookup.
  """
  @spec record(Scope.t(), integer(), String.t(), keyword()) ::
          {:ok, Deploy.t()} | {:error, Ecto.Changeset.t()}
  def record(%Scope{active_project_id: project_id}, story_id, environment, opts \\ []) do
    attrs = %{
      project_id: project_id,
      story_id: story_id,
      environment: environment,
      commit_sha: Keyword.get(opts, :commit_sha),
      version: Keyword.get(opts, :version),
      health_verified_at: Keyword.get(opts, :health_verified_at)
    }

    case get(project_id, story_id, environment) do
      nil -> %Deploy{}
      existing -> existing
    end
    |> Deploy.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc """
  Mark a deploy health-verified, which is what makes it count.

  Separate from `record/4` because the two happen at different moments: the
  deploy goes out, then something checks it. Collapsing them would let a deploy
  that never answered read as done — criterion 1964.
  """
  @spec verify(Scope.t(), integer(), String.t(), DateTime.t()) ::
          {:ok, Deploy.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def verify(%Scope{active_project_id: project_id}, story_id, environment, at \\ nil) do
    case get(project_id, story_id, environment) do
      nil ->
        {:error, :not_found}

      deploy ->
        deploy
        |> Deploy.changeset(%{health_verified_at: at || DateTime.utc_now()})
        |> Repo.update()
    end
  end

  @doc """
  Record the stories a successful deploy carried.

  A deploy ships the application, not one story — so what went out is every
  story that had cleared QA and was not already on that environment. Called
  when the deploy step succeeds, with the health check's own answer: the step
  only reports success after its probe passed, which is what makes
  `health_verified_at` mean something rather than restating that a command
  exited zero.

  Stories still in QA are deliberately not recorded. Their code may well be in
  the image, but "this story is on UAT" is a claim about work that was finished
  and checked, and criterion 1963 puts the deploy *after* `qa_complete` for
  that reason.
  """
  @spec record_environment_deploy(Scope.t(), String.t(), keyword()) :: {:ok, [Deploy.t()]}
  def record_environment_deploy(%Scope{} = scope, environment, opts \\ []) do
    at = Keyword.get(opts, :health_verified_at, DateTime.utc_now())

    recorded =
      scope
      |> stories_clearing_qa()
      |> Enum.flat_map(fn story ->
        attrs = Keyword.merge(opts, health_verified_at: at)

        case record(scope, story.id, environment, attrs) do
          {:ok, deploy} -> [deploy]
          {:error, _changeset} -> []
        end
      end)

    {:ok, recorded}
  end

  defp stories_clearing_qa(%Scope{active_project_id: project_id} = scope) do
    CodeMySpec.Stories.Story
    |> where([s], s.project_id == ^project_id)
    |> Repo.all()
    |> Enum.filter(fn story ->
      match?({true, _}, CodeMySpec.Qa.complete_check(scope, story))
    end)
  end

  @doc "Every deploy on this project, newest first."
  @spec list(Scope.t()) :: [Deploy.t()]
  def list(%Scope{active_project_id: project_id}) do
    Deploy
    |> where([d], d.project_id == ^project_id)
    |> order_by([d], desc: d.updated_at)
    |> Repo.all()
  end

  @doc """
  Whether this story is health-verified on this environment.

  The question the `deploy` requirement asks. Unverified is not deployed: a row
  with no `health_verified_at` is a deploy that went out and never answered.
  """
  @spec deployed?(Scope.t(), integer(), String.t()) :: boolean()
  def deployed?(%Scope{active_project_id: project_id}, story_id, environment) do
    case get(project_id, story_id, environment) do
      %Deploy{health_verified_at: %DateTime{}} -> true
      _ -> false
    end
  end

  @doc """
  Requirement checker for `deploy`: is this story live on UAT and healthy.

  Criterion 1963 — the loop's next work after `qa_complete` is the UAT deploy.
  Prod promotion is the release process's business, not this node's, so this
  asks about UAT only.
  """
  @spec uat_check(Scope.t(), map()) :: {boolean(), map()}
  def uat_check(%Scope{} = scope, %{id: story_id}) do
    case deployed?(scope, story_id, "uat") do
      true -> {true, %{status: "Deployed to UAT and health-verified"}}
      false -> {false, %{status: "Not deployed to UAT, or deployed without a passing health check"}}
    end
  end

  def uat_check(_scope, _entity), do: {false, %{status: "No story to check"}}

  defp get(project_id, story_id, environment) do
    Deploy
    |> where(
      [d],
      d.project_id == ^project_id and d.story_id == ^story_id and d.environment == ^environment
    )
    |> Repo.one()
  end
end
