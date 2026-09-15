defmodule CodeMySpec.QaFixtures do
  @moduledoc """
  Test fixtures for QA attempt lifecycle.

  Provides direct DB insertion of QaAttempt rows for test setup
  that needs a fully-satisfied `qa_complete` requirement without
  going through the full MCP tool surface.

  Used by `CodeMySpecSpex.Fixtures` (the approved bridge) — never
  called from spex test files directly.
  """

  alias CodeMySpec.Qa.QaAttempt
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Users.Scope

  @doc """
  Insert a passed QaAttempt row for a story, satisfying `qa_complete`.

  Accepts a `Scope.t()` and keyword options:
  - `:story_id` — required, integer story id
  - `:agent_id` — optional string agent id (default: "fixture-agent")
  - `:scenarios` — optional list of scenario maps (default: one placeholder)

  Returns `{:ok, attempt}` or `{:error, changeset}`.
  """
  @spec passed_qa_attempt(Scope.t(), keyword()) ::
          {:ok, QaAttempt.t()} | {:error, Ecto.Changeset.t()}
  def passed_qa_attempt(%Scope{} = scope, opts \\ []) do
    story_id = Keyword.fetch!(opts, :story_id)
    agent_id = Keyword.get(opts, :agent_id, "fixture-agent")

    scenarios =
      Keyword.get(opts, :scenarios, [
        %{name: "Placeholder", status: :pass, observation: "Seeded by QaFixtures."}
      ])

    attrs = %{
      story_id: story_id,
      status: :pass,
      scenarios: scenarios,
      issue_ids: [],
      agent_id: agent_id,
      submitted_at: DateTime.utc_now()
    }

    %QaAttempt{}
    |> QaAttempt.changeset(attrs)
    |> Repo.insert()
    |> announce(scope)
  end

  # A QA attempt is a graph input — `qa_complete` is computed from it and
  # `Freshness.story/2` hashes it — so writing one without saying so leaves the
  # graph holding the verdict it reached before the attempt existed.
  #
  # `QaAttempts.submit/2` announces for exactly this reason. This fixture
  # bypasses it to avoid needing a task and a session, and inherited the silence
  # along with the shortcut: criterion 6491 asked a fully-satisfied project for
  # an empty queue and got `qa_complete`, whose stored `false` predated the
  # attempt sitting in the table.
  #
  # Reads used to cover for it by recomputing on the way past. They serve rows
  # now, so a writer that announces nothing is a writer the graph never hears.
  defp announce({:ok, _attempt} = result, %Scope{} = scope) do
    GraphInputs.announce(scope, "Qa")
    result
  end

  defp announce(other, _scope), do: other
end
