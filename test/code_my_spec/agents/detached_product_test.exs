defmodule CodeMySpec.Agents.DetachedProductTest do
  use CodeMySpecTest.DataCase, async: false

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.{Agent, Mailbox, Presence}
  alias CodeMySpec.Conversations.Message

  defmodule Transport do
    def start_agent(_, agent, _) do
      scope = %CodeMySpec.Users.Scope{
        active_project_id: agent.project_id,
        active_account_id: agent.account_id
      }

      {:ok, _} = Mailbox.register(scope, agent.id, Ecto.UUID.generate())
      Presence.track(self(), Presence.topic(agent.project_id), agent.id, %{})
      {:ok, %{agent_id: agent.id}}
    end

    def stop_agent(_, agent, _) do
      Presence.untrack(self(), Presence.topic(agent.project_id), agent.id)
      :ok
    end

    def dispatch_message(_, _, _, _, _), do: {:error, :busy}
  end

  defmodule RefusingTransport do
    def start_agent(_, _, _), do: {:error, :no_credential}
  end

  setup do
    previous =
      for key <- [:env, :desktop_agent_transport, :agent_transport, :detached_agents_root],
          do: {key, Application.fetch_env(:code_my_spec, key)}

    root = CodeMySpec.TempFile.owned_dir("detached-product")
    Application.put_env(:code_my_spec, :env, :desktop)
    Application.put_env(:code_my_spec, :desktop_agent_transport, Transport)
    Application.put_env(:code_my_spec, :agent_transport, Transport)
    Application.put_env(:code_my_spec, :detached_agents_root, root)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:code_my_spec, key, value)
          :error -> Application.delete_env(:code_my_spec, key)
        end
      end
    end)

    scope = CodeMySpec.UsersFixtures.full_scope_fixture()
    {:ok, _} = Agents.put_model_setting(scope, :product, "claude-code", "claude-opus-5-5")
    %{scope: scope}
  end

  test "product starts without a checkout, keeps its conversation and introduces itself once", %{
    scope: scope
  } do
    assert CodeMySpec.WorkingCopies.main(scope) == nil
    assert {:ok, product} = Agents.ensure_product_agent(scope)
    assert product.execution_mode == :detached
    assert product.working_copy_id == nil
    assert product.provider == "claude-code"
    assert product.model == "claude-opus-5-5"
    assert File.dir?(product.working_copy)
    assert CodeMySpec.WorkingCopies.main(scope) == nil
    assert Agents.main_agent(scope) == nil
    assert {:ok, conversation_id} = Agents.conversation_id(scope, product.id)
    assert {:ok, same} = Agents.ensure_product_agent(scope)
    assert same.id == product.id
    assert {:ok, ^conversation_id} = Agents.conversation_id(scope, same.id)

    assert Repo.aggregate(
             from(m in Message, where: m.conversation_id == ^conversation_id),
             :count
           ) == 1
  end

  test "detached project tools cannot inherit a previously selected checkout", %{scope: scope} do
    stale = %{scope | active_working_copy_id: Ecto.UUID.generate(), cwd: "/some/other/project"}
    product = %Agent{execution_mode: :detached, role: :product}
    clean = Agents.scope_for(stale, product)
    assert clean.active_working_copy_id == nil
    assert clean.cwd == nil
    assert clean.active_project_id == scope.active_project_id
    assert clean.user == scope.user
  end

  test "sending to detached Product restores it after process presence is lost", %{scope: scope} do
    {:ok, product} = Agents.ensure_product_agent(scope)
    Presence.untrack(self(), Presence.topic(scope.active_project_id), product.id)
    refute Agents.present?(scope, product)

    assert {:ok, [%{"status" => "stopped"}]} =
             CodeMySpec.Agents.Tools.ListAgents.script_result(%{}, %{scope: scope})

    assert {:ok, :queued} = Agents.message_agent(scope, product.id, "Setup status")
    assert Agents.present?(scope, product)
    assert {:ok, restored} = Agents.fetch_agent(scope, product.id)
    refute restored.mailbox_generation == product.mailbox_generation
  end

  test "startup failure reaches the caller and retry reuses the product row", %{scope: scope} do
    Application.put_env(:code_my_spec, :desktop_agent_transport, RefusingTransport)
    assert {:error, :no_credential} = Agents.ensure_product_agent(scope)
    assert [product] = Agents.list_agents(scope)
    assert product.status == :starting
    assert {:ok, conversation_id} = Agents.conversation_id(scope, product.id)

    assert Repo.aggregate(
             from(m in Message, where: m.conversation_id == ^conversation_id),
             :count
           ) == 0

    Application.put_env(:code_my_spec, :desktop_agent_transport, Transport)
    assert {:ok, retried} = Agents.ensure_product_agent(scope)
    assert retried.id == product.id
    assert retried.status == :running
  end

  test "hosted project without an execution host does not create a pretend agent", %{scope: scope} do
    Application.put_env(:code_my_spec, :env, :test)
    assert {:error, :no_execution_host} = Agents.ensure_product_agent(scope)
    assert Agents.list_agents(scope) == []
  end

  test "coding agents still require a copy", %{
    scope: scope
  } do
    attrs = %{
      engine: :alloy,
      provider: "claude-code",
      role: :coding,
      working_copy: "/tmp",
      project_id: scope.active_project_id,
      account_id: scope.active_account_id
    }

    refute Agent.changeset(%Agent{}, attrs).valid?
    refute Agent.changeset(%Agent{}, Map.put(attrs, :execution_mode, :detached)).valid?
  end

  defp ready_for_setup(scope) do
    {:ok, _} = Agents.put_model_setting(scope, :main, "claude-code", "claude-opus-5-5")

    CodeMySpec.Projects.Onboarding.save(scope, %{
      "onboarding" => %{
        "description" => "Meal planning for families",
        "starting_point" => "new",
        "destination" => "local"
      }
    })
  end

  test "setup starts one detached Main and records one durable handoff on retries", %{
    scope: scope
  } do
    {:ok, _} = ready_for_setup(scope)
    assert {:ok, project, main} = Agents.start_project_setup(scope)
    assert main.role == :main
    assert main.execution_mode == :detached
    assert main.working_copy_id == nil
    assert main.model == "claude-opus-5-5"
    assert CodeMySpec.Projects.Onboarding.phase(project) == :stories
    assert project.onboarding.setup_agent_id == main.id
    assert Agents.main_agent(scope).id == main.id
    assert {:ok, _, again} = Agents.start_project_setup(scope)
    assert again.id == main.id
    assert {:ok, conversation_id} = Agents.conversation_id(scope, main.id)
    messages = Repo.all(from(m in Message, where: m.conversation_id == ^conversation_id))
    assert length(messages) == 1
    assert inspect(hd(messages).content) =~ "Product has handed development environment setup"
    assert length(Agents.list_agents(scope)) == 1
  end

  test "opening onboarding conversations keeps the team detached while the main copy is offline",
       %{scope: scope} do
    {:ok, _} = ready_for_setup(scope)
    {:ok, product} = Agents.ensure_product_agent(scope)
    {:ok, _, main} = Agents.start_project_setup(scope)
    {:ok, copy} = CodeMySpec.WorkingCopies.fetch(scope.active_working_copy_id)

    copy
    |> Ecto.Changeset.change(main: true, root: "/tmp/offline-onboarding-main")
    |> Repo.update!()

    {:ok, same_main} = Agents.ensure_main_agent(scope)
    {:ok, same_product} = Agents.ensure_product_agent(scope)
    assert same_main.id == main.id
    assert same_product.id == product.id
    assert same_main.execution_mode == :detached
    assert same_product.execution_mode == :detached
    assert Agents.present?(scope, same_main)
    assert Agents.present?(scope, same_product)
  end

  test "the first main copy moves the onboarding team and retains both conversations", %{
    scope: scope
  } do
    {:ok, _} = ready_for_setup(scope)
    {:ok, product} = Agents.ensure_product_agent(scope)
    {:ok, _, main} = Agents.start_project_setup(scope)
    {:ok, copy} = CodeMySpec.WorkingCopies.fetch(scope.active_working_copy_id)

    copy =
      copy |> Ecto.Changeset.change(main: true, root: "/tmp/onboarding-main") |> Repo.update!()

    assert %{started: [], failed: []} = Agents.ensure_copy_agents(scope, copy)
    {:ok, main_conversation} = Agents.conversation_id(scope, main.id)
    {:ok, product_conversation} = Agents.conversation_id(scope, product.id)

    assert {:ok, moved} =
             Agents.move_main_agent(%{scope | active_working_copy_id: nil, cwd: nil}, copy)

    assert moved.id == main.id
    assert moved.execution_mode == :working_copy
    assert moved.working_copy_id == copy.id
    assert {:ok, retained_product} = Agents.fetch_agent(scope, product.id)
    assert retained_product.execution_mode == :working_copy
    assert retained_product.working_copy_id == copy.id
    assert {:ok, ^main_conversation} = Agents.conversation_id(scope, main.id)
    assert {:ok, ^product_conversation} = Agents.conversation_id(scope, product.id)
    assert :none = Agents.move_main_agent(scope, copy)
    assert length(Agents.list_agents(scope)) == 2
  end

  test "incomplete choices do not create Main or unlock stories", %{scope: scope} do
    assert {:error, :incomplete_onboarding} = Agents.start_project_setup(scope)
    assert Agents.list_agents(scope) == []
  end

  test "failed setup startup keeps handoff pending and retries the same agent", %{scope: scope} do
    {:ok, _} = ready_for_setup(scope)
    Application.put_env(:code_my_spec, :desktop_agent_transport, RefusingTransport)
    assert {:error, :no_credential} = Agents.start_project_setup(scope)
    {:ok, project} = CodeMySpec.Projects.Onboarding.fetch(scope)
    assert CodeMySpec.Projects.Onboarding.phase(project) == :setup_handoff
    [main] = Agents.list_agents(scope)
    Application.put_env(:code_my_spec, :desktop_agent_transport, Transport)
    assert {:ok, _, retried} = Agents.start_project_setup(scope)
    assert retried.id == main.id
  end

  test "setup without a host stays pending", %{scope: scope} do
    {:ok, _} = ready_for_setup(scope)
    Application.put_env(:code_my_spec, :env, :test)
    assert {:error, :no_execution_host} = Agents.start_project_setup(scope)
    assert Agents.list_agents(scope) == []
    {:ok, project} = CodeMySpec.Projects.Onboarding.fetch(scope)
    assert CodeMySpec.Projects.Onboarding.phase(project) == :setup_handoff
  end

  test "another user's project scope is refused", %{scope: scope} do
    other = CodeMySpec.UsersFixtures.user_fixture()

    assert {:error, :not_found} =
             Agents.ensure_product_agent(%{scope | user: other, user_id: other.id})

    assert Agents.list_agents(scope) == []
  end
end
