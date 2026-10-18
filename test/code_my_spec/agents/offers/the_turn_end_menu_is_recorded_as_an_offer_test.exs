defmodule CodeMySpec.Agents.Offers.TheTurnEndMenuIsRecordedAsAnOfferTest do
  @moduledoc """
  b75b0198 step 1: `StopDecision`'s problems and menu, and the analysis
  findings push, each record an offer and send what they sent before.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.{AnalysisFixtures, DevicesFixtures, ProblemsFixtures}
  import CodeMySpec.{StoriesFixtures, UsersFixtures}

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.AnalysisReport
  alias CodeMySpec.Agents.Mailbox
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Agents.StopDecision
  alias CodeMySpec.Configurations
  alias CodeMySpec.Conversations
  alias CodeMySpec.Conversations.Message
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.AcceptanceCriteria
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport

  @mine "lib/my_app/mine.ex"
  @spex_path "test/spex/811_provisioning/criterion_6493_a_step_reports_its_provider_spex.exs"

  setup do
    scope = full_scope_fixture()
    RecordingAgentTransport.listen(scope)

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    %{scope: scope, copy: copy}
  end

  defp agent(ctx, role, continuous) do
    {:ok, agent} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: role,
        continuous: continuous,
        status: :running,
        working_copy: "/tmp/menu-offer-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.copy.id
      })

    AgentPresence.present(agent)

    {:ok, _} =
      Conversations.find_or_create_agent_conversation(
        ctx.scope.active_account_id,
        ctx.scope.active_project_id,
        agent.id
      )

    on_exit(fn ->
      :persistent_term.erase({StopDecision, :decision, agent.id})
      :persistent_term.erase({StopDecision, :continuing, agent.id})
    end)

    agent
  end

  defp linked_texts(offer) do
    Enum.map(offer.messages, &(Repo.get!(Message, &1.message_id) |> Message.text()))
  end

  defp dispatched(id) do
    assert_receive {:agent_dispatch, ^id, _ref, message}, 2_000
    message
  end

  test "the continuing menu records a menu offer on the held task", ctx do
    agent = agent(ctx, "qa", true)
    task_id = Ecto.UUID.generate()

    task = %CodeMySpec.Sessions.Task{
      id: task_id,
      status: :active,
      requirement_name: "qa_complete",
      started_at: DateTime.utc_now()
    }

    holding = %{agent | tasks: [task]}
    expected = StopDecision.decide(ctx.scope, holding)
    :ok = StopDecision.deliver(ctx.scope, holding, [])

    assert dispatched(agent.id) == expected
    assert expected =~ "loop is still running"

    assert [offer] = Offers.list_for_agent(agent.id)
    assert {offer.kind, offer.subject_type, offer.subject_key} == {:menu, "menu", task_id}
    assert linked_texts(offer) == [expected]
  end

  describe "problems" do
    setup ctx do
      tmp = CodeMySpec.TempFile.owned_dir("test")
      scope = put_fixture_environment(%{ctx.scope | cwd: tmp}, Environment.new(:local, tmp))

      Configurations.get_or_create(scope)

      for path <- [@mine, @spex_path] do
        File.mkdir_p!(Path.join(tmp, Path.dirname(path)))
        File.write!(Path.join(tmp, path), "defmodule M do\nend\n")
      end

      {:ok, _} = FileSync.sync(scope, base_dir: tmp)
      story = story_fixture(scope)

      {:ok, _criterion} =
        AcceptanceCriteria.create_criterion(scope, story, %{
          description: "a step reports its provider",
          spec_path: @spex_path
        })

      {:ok, _} = Stories.set_specs_ready(scope, Stories.get_story(scope, story.id), true)
      problem_fixture(scope, %{source: "spex", severity: :error, file_path: @spex_path})
      fresh_analysis_runs_fixture(scope)

      %{scope: scope}
    end
  end

  test "analysis findings link the problems offer to its durable mailbox message", ctx do
    agent = agent(ctx, "coding", true)
    scope = %{ctx.scope | active_working_copy_id: ctx.copy.id}

    :ok = AnalysisReport.deliver(scope, "credo", [%{severity: :error}], agent.id)

    message = dispatched(agent.id)
    assert message =~ "Your credo run finished: 1 blocking problem"

    assert [offer] = Offers.list_for_agent(agent.id)
    assert {offer.kind, offer.subject_type, offer.subject_key} == {:problems, "analysis", "credo"}
    assert [link] = offer.messages
    assert [%{message_id: message_id}] = Mailbox.entries(scope, agent.id)
    assert message_id == link.message_id
  end

  test "a clean run answered to its asker records no offer", ctx do
    agent = agent(ctx, "coding", true)
    scope = %{ctx.scope | active_working_copy_id: ctx.copy.id}

    :ok = AnalysisReport.deliver(scope, "credo", [], agent.id)

    assert dispatched(agent.id) =~ "no blocking problems"
    assert Offers.list_for_agent(agent.id) == []
  end
end
