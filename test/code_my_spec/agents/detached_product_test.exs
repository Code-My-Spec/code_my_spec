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

    def dispatch_message(_, _, _, _, _), do: {:error, :busy}
  end

  defmodule RefusingTransport do
    def start_agent(_, _, _), do: {:error, :no_credential}
  end

  setup do
    previous =
      for key <- [:env, :desktop_agent_transport, :detached_agents_root],
          do: {key, Application.fetch_env(:code_my_spec, key)}

    root = CodeMySpec.TempFile.owned_dir("detached-product")
    Application.put_env(:code_my_spec, :env, :desktop)
    Application.put_env(:code_my_spec, :desktop_agent_transport, Transport)
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

  test "ordinary agents still require a copy and detached mode is only for product", %{
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

  test "another user's project scope is refused", %{scope: scope} do
    other = CodeMySpec.UsersFixtures.user_fixture()

    assert {:error, :not_found} =
             Agents.ensure_product_agent(%{scope | user: other, user_id: other.id})

    assert Agents.list_agents(scope) == []
  end
end
