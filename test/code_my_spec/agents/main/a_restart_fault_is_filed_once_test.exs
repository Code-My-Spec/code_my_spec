defmodule CodeMySpec.Agents.Main.ARestartFaultIsFiledOnceTest do
  @moduledoc """
  Issue b2752ae3 â "A restart changed nothing: <reason>" was filed repeatedly
  for the same agent and reason. The check guarding it, `Issues.open_issue_titled?/2`
  followed by `Issues.create_issue/2`, is two steps rather than one, and nothing
  made the second step refuse a duplicate on its own: the existing unique index
  on `issues` is `(title, story_id, project_id)`, these fault issues all carry a
  `nil` story_id, and Postgres treats NULL as distinct from NULL in a unique
  index â so any number of rows with the same title, the same project, and a
  null story_id could already coexist, race or no race.

  A second, partial unique index closes that gap specifically for storyless
  issues, and `Agents.Main.file_fault/5` now treats losing that race as
  "already raised" rather than a bare changeset error.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.IntegrationsFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Main
  alias CodeMySpec.Agents.Main.RestartRepository
  alias CodeMySpec.Issues
  alias CodeMySpecTest.AgentPresence

  setup do
    scope = full_scope_fixture()
    integration_fixture(scope.user, %{provider: :anthropic})

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    %{scope: scope, copy: copy}
  end

  defp an_unresolved_agent(scope, copy, reason) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        continuous: true,
        status: :running,
        working_copy: "/tmp/restart-fault-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    AgentPresence.present(agent)

    # Never having spoken since the restart is what makes it unresolved â
    # `RestartRepository.outstanding/1`'s own `worked?/2` only clears a restart
    # once the agent speaks afterward, so a silent agent stays unresolved
    # without any timestamp fiddling.
    {:ok, _restart} = RestartRepository.record(agent, reason)

    agent
  end

  describe "the application-level guard" do
    test "two reads of the same unresolved restart file the fault once", ctx do
      reason = "it stopped answering after its last turn (#{System.unique_integer([:positive])})"
      an_unresolved_agent(ctx.scope, ctx.copy, reason)

      _ = Main.list_agent_work(ctx.scope)
      _ = Main.list_agent_work(ctx.scope)

      title = "A restart changed nothing: #{reason}"

      matching =
        ctx.scope
        |> Issues.list_by_status(:incoming)
        |> Enum.filter(&(&1.title == title))

      assert length(matching) == 1,
             """
             Two reads of the same still-unresolved restart filed the fault more
             than once for the same agent and reason.

             matching issues: #{inspect(matching)}
             """
    end
  end

  describe "the database-level guard" do
    test "a second storyless issue with the same title and project is refused", ctx do
      title = "A restart changed nothing: the same fault, raced"

      assert {:ok, _first} =
               Issues.create_issue(ctx.scope, %{
                 title: title,
                 severity: :high,
                 scope: :framework,
                 description: "first writer"
               })

      assert {:error, changeset} =
               Issues.create_issue(ctx.scope, %{
                 title: title,
                 severity: :high,
                 scope: :framework,
                 description: "second writer, racing the first"
               })

      assert {_message, opts} = changeset.errors[:title]
      assert Keyword.get(opts, :constraint) == :unique
    end
  end
end
