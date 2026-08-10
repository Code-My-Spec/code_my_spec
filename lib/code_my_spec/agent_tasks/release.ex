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
  def command(%Scope{} = scope, task) do
    if journeys_complete?(scope), do: release_command(scope, task), else: journeys_first()
  end

  # The prompt opened by asserting "the user journeys are complete" and nothing
  # checked. The graph stopped handing this out as a node (d207ad38), so the
  # only way in is an explicit request — and a request made too early got the
  # full ceremony, tag step included, on the strength of a sentence claiming a
  # precondition nobody had tested.
  #
  # Journey *results*, not the plan: a plan says the walkthrough was designed,
  # a result says somebody walked it.
  defp journeys_complete?(%Scope{environment: env}) do
    match?({:ok, _}, Environments.read_file(env, Paths.qa_journey_result()))
  end

  defp journeys_first do
    {:ok,
     """
     # Not yet — the user journeys come first

     A release cut now would ship work nobody has walked through end to end.

     `#{Paths.qa_journey_result()}` does not exist, so no journey has been
     recorded as run against this cycle's work.

     Finish the user journeys, then ask for the release again. This refusal
     publishes and deploys nothing, and the UAT deploys stay exactly where
     they are.
     """}
  end

  defp release_command(%Scope{} = scope, _task) do
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
        proposed version and the notes. It reaches them wherever they are:
        the question goes out as a phone push notification as well as to the
        terminal, so a release does not sit unanswered because nobody happens
        to be at a keyboard. Deploy NOTHING before an explicit yes. If the
        user declines, stand down: no deploy, no tag, and the release stays
        open for a later cycle.
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

    Enum.reject(deployed, &released?(released, &1))
  end

  # `story_1` is a substring of `story_12`, `story_19` and `story_100`, so
  # `String.contains?/2` called story 1 released the moment any manifest named
  # one of those. It failed open — the `release` requirement read satisfied for
  # work that had never shipped — and on any project past nine stories that is
  # the ordinary case rather than an edge one.
  #
  # The boundaries are what make this a token match instead of a prefix match:
  # `story_1` does not match inside `story_12`, because the character after the
  # `1` is a word character and there is no boundary there.
  defp released?(released, id) do
    Regex.match?(~r/\bstory_#{Regex.escape(to_string(id))}\b/, released)
  end

  defp deployed_story_ids(env) do
    case Environments.list_directory(env, Paths.devops_deploys_dir()) do
      {:ok, entries} -> entries |> Enum.flat_map(&deployed_story_id/1) |> Enum.sort()
      _ -> []
    end
  end

  # A list so it composes with flat_map: one element for a deploy record, none
  # for anything else in the directory.
  defp deployed_story_id(entry) do
    case Regex.run(~r/story_(\d+)\.md$/, entry) do
      [_, id] -> [id]
      nil -> []
    end
  end

  # Concatenate every release record's contents — coverage is "the story
  # token appears in some release manifest".
  defp released_manifest(env) do
    case Environments.list_directory(env, Paths.releases_dir()) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map_join("\n", &read_release(env, &1))

      _ ->
        ""
    end
  end

  # An unreadable release record reads as empty rather than raising: it means
  # the stories it covered look unreleased, which stops a release rather than
  # waving one through.
  defp read_release(env, entry) do
    path = Path.join(Paths.releases_dir(), Path.basename(entry))

    case Environments.read_file(env, path) do
      {:ok, content} -> content
      _ -> ""
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
