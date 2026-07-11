defmodule CodeMySpec.AgentTasks.Release do
  @moduledoc """
  Prod release at the end of the cycle (Story 859).

  Per-story deploys stop at UAT; prod is a formal release. It happens only
  after the user journeys are complete and updated, it requires the user's
  explicit approval, and it ships with ceremony: release notes compiled from
  the stories it contains, an agent-proposed semver version, an annotated
  git tag, a GitHub Release, and a record at `.code_my_spec/releases/`.

  Recurrence is content-based: the requirement is satisfied only while every
  UAT deploy record's story is covered by some release record's `## Stories`
  manifest. A new UAT deploy reopens the release — each cycle naturally ends
  by demanding a prod release.
  """

  alias CodeMySpec.Environments
  alias CodeMySpec.Paths
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope

  @doc """
  One-line description surfaced by the requirement graph when this task is
  the next thing to do.
  """
  def dispatch(_node) do
    "Cut the prod release: compile release notes from the stories on UAT " <>
      "since the last release, propose a semver version, get the user's " <>
      "explicit approval, then tag, publish, deploy prod, and record it. " <>
      "Use when the user journeys are complete and UAT holds unreleased work."
  end

  @doc """
  Generate the prompt for the release session.
  """
  @spec command(Scope.t(), map()) :: {:ok, String.t()}
  def command(%Scope{} = scope, _task) do
    unreleased = unreleased_story_ids(scope)
    manifest = manifest_section(scope, unreleased)

    {:ok,
     """
     # Prod Release Session

     The user journeys are complete — time to cut the release. Per-story
     deploys stopped at UAT; this session promotes the cycle's work to prod
     with full ceremony.

     ## What's on UAT since the last release

     #{manifest}

     ## Procedure

     1. **Compile the release notes** from the stories above — user-facing
        language built from their titles and descriptions, not commit logs.
        Lead with what the user can now do.
     2. **Propose a semver version**: read the manifest and judge
        major/minor/patch from the changes. State your reasoning in one line.
     3. **Get the user's explicit approval** — call `ask_user` with the
        proposed version and the notes. Deploy NOTHING before an explicit
        yes. If the user declines, stand down: no deploy, no tag, and the
        release stays open for a later cycle.
     4. **Publish** — after approval only:
        - Annotated git tag `v<version>` whose message is the release notes.
        - GitHub Release for the tag (`gh release create`) carrying the
          same notes.
        - Deploy prod (`kamal deploy` with the prod config) and verify
          `https://<domain>/health` answers 200 over TLS.
     5. **Record it** — write `.code_my_spec/releases/<version>.md` with the
        notes, the verified prod health check, and a `## Stories` section
        listing every deploy this release covers (one `story_<id>` per
        line). The record's manifest is what closes the requirement — an
        uncovered UAT deploy reopens it.

     ## Done signal

     Call `evaluate_task` — the checker confirms every UAT deploy record is
     covered by a release manifest.
     """}
  end

  @doc """
  Evaluate: every UAT deploy record's story is covered by a release record.

  Called as the requirement's delegate (entity = Project) and as the task
  evaluator. Content-based recurrence: no timestamps, just coverage — a
  deploy record whose `story_<id>` appears in no release manifest means
  unreleased work on UAT.

  No deploy records at all is satisfied: nothing shipped, nothing to release.
  """
  @spec evaluate(Scope.t(), map() | struct()) :: {:ok, :valid} | {:ok, :invalid, String.t()}
  def evaluate(%Scope{} = scope, _entity) do
    case unreleased_story_ids(scope) do
      [] ->
        {:ok, :valid}

      unreleased ->
        {:ok, :invalid,
         "UAT holds unreleased work: #{Enum.map_join(unreleased, ", ", &"story_#{&1}")}. " <>
           "Cut a prod release whose `## Stories` manifest covers them " <>
           "(record at `#{Paths.releases_dir()}/<version>.md`)."}
    end
  end

  # ── Coverage ─────────────────────────────────────────────────────────

  defp unreleased_story_ids(%Scope{environment: env} = _scope) do
    deployed = deployed_story_ids(env)
    released = released_manifest(env)

    Enum.reject(deployed, &String.contains?(released, "story_#{&1}"))
  end

  defp deployed_story_ids(env) do
    case Environments.list_directory(env, Paths.devops_deploys_dir()) do
      {:ok, entries} ->
        entries
        |> Enum.flat_map(fn entry ->
          case Regex.run(~r/story_(\d+)\.md$/, entry) do
            [_, id] -> [id]
            nil -> []
          end
        end)
        |> Enum.sort()

      _ ->
        []
    end
  end

  # Concatenate every release record's contents — coverage is "the story
  # token appears in some release manifest".
  defp released_manifest(env) do
    case Environments.list_directory(env, Paths.releases_dir()) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map_join("\n", fn entry ->
          path = Path.join(Paths.releases_dir(), Path.basename(entry))

          case Environments.read_file(env, path) do
            {:ok, content} -> content
            _ -> ""
          end
        end)

      _ ->
        ""
    end
  end

  # ── Prompt helpers ───────────────────────────────────────────────────

  defp manifest_section(_scope, []) do
    "No unreleased deploy records found — verify `#{Paths.devops_deploys_dir()}/` " <>
      "before proceeding; a release with nothing in it is a no-op."
  end

  defp manifest_section(scope, story_ids) do
    Enum.map_join(story_ids, "\n", fn id ->
      title = story_title(scope, id)
      "- `story_#{id}` — #{title}"
    end)
  end

  defp story_title(scope, id) do
    case Integer.parse(id) do
      {int_id, ""} ->
        case Stories.get_story(scope, int_id) do
          %{title: title, description: description} ->
            "#{title}: #{description}"

          _ ->
            "(story not found — include it by id)"
        end

      _ ->
        "(unparseable story id)"
    end
  rescue
    _ -> "(story lookup failed — include it by id)"
  end
end
