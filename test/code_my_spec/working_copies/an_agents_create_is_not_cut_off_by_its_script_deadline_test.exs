defmodule CodeMySpec.WorkingCopies.AnAgentsCreateIsNotCutOffByItsScriptDeadlineTest do
  @moduledoc """
  An agent asking for a working copy is answered at once and told how the
  create ended. Made while it waited, the create outlived `run_script`'s 30s
  deadline on a loaded machine and was cut off after the harness had made the
  checkout and before the server recorded it, leaving an orphan.
  """
  use CodeMySpecSpex.Case, async: false

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup ctx do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    RecordingAgentTransport.listen(ctx)

    {:ok, main} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "main",
        status: :running,
        working_copy: "/tmp/create-async-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.scope.active_working_copy_id
      })

    AgentPresence.present(main)
    %{main: main}
  end

  test "it is answered at once, and told how the create ended", ctx do
    :ok = Fixtures.without_checkouts(ctx.scope)

    reply =
      ToolLibrary.run("create_working_copy", %{label: "main-fixes"}, %{
        scope: ctx.scope,
        current_scope: ctx.scope,
        agent_id: ctx.main.id
      })

    assert response_text(reply) =~ "you'll be messaged how it ends"

    main_id = ctx.main.id
    assert_receive {:agent_dispatch, ^main_id, _ref, told}, 5_000
    assert told =~ "The working copy was not made."
    assert told =~ ~r/harness|machine/i
  end
end
