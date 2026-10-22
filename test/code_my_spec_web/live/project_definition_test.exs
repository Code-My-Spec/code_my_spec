defmodule CodeMySpecWeb.ProjectDefinitionTest do
  use CodeMySpecTest.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias CodeMySpec.{Conversations, ScreenState}
  alias CodeMySpec.Projects.Onboarding

  defmodule Transport do
    def start_agent(_, agent, _) do
      scope = %CodeMySpec.Users.Scope{
        active_project_id: agent.project_id,
        active_account_id: agent.account_id
      }

      {:ok, _} = CodeMySpec.Agents.Mailbox.register(scope, agent.id, Ecto.UUID.generate())

      CodeMySpec.Agents.Presence.track(
        self(),
        CodeMySpec.Agents.Presence.topic(agent.project_id),
        agent.id,
        %{}
      )

      {:ok, %{agent_id: agent.id}}
    end

    def dispatch_message(_, _, _, _, _), do: {:error, :busy}
  end

  setup [:register_log_in_setup_account]

  setup %{scope: scope} do
    project = CodeMySpec.ProjectsFixtures.project_fixture(scope)
    scope = %{scope | active_project_id: project.id, active_project: project}

    {:ok, conversation} =
      Conversations.find_or_create_session_conversation(
        scope.active_account_id,
        project.id,
        "definition-test"
      )

    {:ok, _} = ScreenState.put(scope, %{dynamic_view: "definition", open_panels: ["dynamic"]})

    %{
      project: project,
      scope: scope,
      path: "/app/projects/#{project.id}/agent-conversation?conversation=#{conversation.id}"
    }
  end

  test "stories remain hidden until setup is handed off, then appear without refreshing", %{
    conn: conn,
    path: path,
    scope: scope
  } do
    {:ok, view, _} = live(conn, path)
    assert has_element?(view, "[data-test=onboarding-progress]")
    refute has_element?(view, "button[phx-value-view=stories]")

    {:ok, _} =
      Onboarding.save(scope, %{
        "onboarding" => %{
          "description" => "Meal planning",
          "starting_point" => "new",
          "destination" => "local"
        }
      })

    assert render(view) =~ "Product can now hand environment setup to Main"
    refute has_element?(view, "button[phx-value-view=stories]")
    {:ok, _} = Onboarding.record_handoff(scope, Ecto.UUID.generate())
    assert render(view) =~ "Main has the setup request"
    assert has_element?(view, "button[phx-value-view=stories]")
  end

  test "named conversation opens without main and saves definition across refresh", %{
    conn: conn,
    path: path,
    scope: scope
  } do
    {:ok, view, _} = live(conn, path)
    refute has_element?(view, "[data-test=no-main-working-copy]")
    assert has_element?(view, "[data-test=project-definition]")

    view
    |> form("#project-definition-form",
      definition: %{
        description: "Help families plan meals",
        starting_point: "new",
        destination: "local"
      }
    )
    |> render_submit()

    assert has_element?(view, "[role=status]", "Project choices saved")
    {:ok, project} = Onboarding.fetch(scope)
    assert project.onboarding.description == "Help families plan meals"
    assert project.onboarding.starting_point == :new
    {:ok, refreshed, _} = live(conn, path)

    assert has_element?(
             refreshed,
             "textarea[name='definition[description]']",
             "Help families plan meals"
           )

    assert has_element?(
             refreshed,
             "select[name='definition[starting_point]'] option[selected][value=new]"
           )
  end

  test "agent-side saves refresh the panel and preserve unsaved user edits", %{
    conn: conn,
    path: path,
    scope: scope
  } do
    {:ok, view, _} = live(conn, path)

    {:ok, _} =
      Onboarding.save(scope, %{
        onboarding: %{description: "Recorded by product", starting_point: :new}
      })

    assert has_element?(view, "textarea[name='definition[description]']", "Recorded by product")
    refute has_element?(view, "[data-test=definition-updated]")

    view
    |> form("#project-definition-form", definition: %{description: "My unsaved refinement"})
    |> render_change()

    {:ok, _} = Onboarding.save(scope, %{onboarding: %{description: "A newer saved brief"}})
    assert has_element?(view, "textarea[name='definition[description]']", "My unsaved refinement")

    assert has_element?(
             view,
             "[data-test=definition-updated]",
             "Your unsaved edits are still here"
           )

    view |> element("[data-test=definition-updated] button") |> render_click()
    assert has_element?(view, "textarea[name='definition[description]']", "A newer saved brief")
    refute has_element?(view, "[data-test=definition-updated]")
  end

  test "setup context is collapsed while product's response stays visible", %{
    conn: conn,
    path: path,
    scope: scope
  } do
    conversation_id = URI.decode_query(URI.parse(path).query)["conversation"]
    conversation = Conversations.get_agent_conversation_by_id(scope, conversation_id)
    context = "Internal project context with saved source and environment decisions"
    {:ok, _} = Conversations.add_message(conversation, :operator, context, "setup")

    {:ok, _} =
      Conversations.add_message(
        conversation,
        :assistant,
        "What do you want to build?",
        "agent:product"
      )

    {:ok, view, _} = live(conn, path)

    assert has_element?(
             view,
             "details[data-test=project-context]:not([open]) summary",
             "Project context"
           )

    assert has_element?(view, "details[data-test=project-context]", context)
    assert has_element?(view, "[data-test=message]", "What do you want to build?")
    refute has_element?(view, "[data-test=message]", context)
  end

  test "existing GitHub source is persisted and private access offers integration settings", %{
    conn: conn,
    path: path,
    scope: scope
  } do
    {:ok, view, _} = live(conn, path)

    view
    |> form("#project-definition-form", definition: %{starting_point: "existing"})
    |> render_change()

    assert has_element?(view, "a[href='/app/users/settings']", "connect GitHub")

    view
    |> form("#project-definition-form",
      definition: %{
        starting_point: "existing",
        source_kind: "github",
        repository_url: "https://github.com/example/source",
        ref: "main"
      }
    )
    |> render_submit()

    {:ok, project} = Onboarding.fetch(scope)

    assert [%{kind: :github, repository_url: "https://github.com/example/source", ref: "main"}] =
             project.sources
  end

  test "Define enters product's conversation without creating a checkout or main", %{
    conn: conn,
    project: project,
    scope: scope
  } do
    previous =
      for key <- [:env, :desktop_agent_transport, :detached_agents_root],
          do: {key, Application.fetch_env(:code_my_spec, key)}

    Application.put_env(:code_my_spec, :env, :desktop)
    Application.put_env(:code_my_spec, :desktop_agent_transport, Transport)

    Application.put_env(
      :code_my_spec,
      :detached_agents_root,
      CodeMySpec.TempFile.owned_dir("define-cockpit")
    )

    on_exit(fn ->
      for {key, prior} <- previous do
        case prior do
          {:ok, value} -> Application.put_env(:code_my_spec, key, value)
          :error -> Application.delete_env(:code_my_spec, key)
        end
      end
    end)

    {:ok, _} =
      CodeMySpec.Agents.put_model_setting(scope, :product, "claude-code", "claude-opus-5-5")

    {:ok, view, _} =
      conn
      |> live("/app/projects/#{project.id}/agent-conversation?role=product")
      |> follow_redirect(conn)

    [product] = CodeMySpec.Agents.list_agents(scope)
    assert product.role == :product
    assert product.execution_mode == :detached
    assert product.working_copy_id == nil
    assert CodeMySpec.WorkingCopies.main(scope) == nil
    assert CodeMySpec.Agents.main_agent(scope) == nil
    assert has_element?(view, "[data-test=project-definition]")
    refute has_element?(view, "[data-test=no-main-working-copy]")
    refute has_element?(view, "[data-test=product-unavailable]")

    refute has_element?(view, "[data-test=agent-pending-message] [data-test=project-context]")

    refute has_element?(view, "[data-test=queued-message-text]", "Begin defining this project")
    {:ok, conversation_id} = CodeMySpec.Agents.conversation_id(scope, product.id)
    assert has_element?(view, "#agent-scroll-#{conversation_id}")

    conversation = Conversations.get_agent_conversation_by_id(scope, conversation_id)
    before_messages = Conversations.list_messages(conversation)
    {:ok, _} = Onboarding.save(scope, %{onboarding: %{description: "Product recorded our plan"}})

    assert has_element?(
             view,
             "textarea[name='definition[description]']",
             "Product recorded our plan"
           )

    assert Conversations.list_messages(conversation) == before_messages

    view |> element("[data-test=panel-tab-activity]") |> render_click()

    assert has_element?(
             view,
             "[data-test=team-detached-agent][data-agent-id='#{product.id}']",
             "product"
           )

    send(view.pid, {:agent_started, product})
    assert has_element?(view, "#agent-scroll-#{conversation_id}")
    assert CodeMySpec.Agents.main_agent(scope) == nil

    {:ok, reopened, _} =
      conn
      |> live("/app/projects/#{project.id}/agent-conversation?role=product")
      |> follow_redirect(conn)

    assert has_element?(reopened, "#agent-scroll-#{conversation_id}")
    assert has_element?(reopened, "[data-test=panel-activity][data-panel-open=true]")
    assert [%{id: id}] = CodeMySpec.Agents.list_agents(scope)
    assert id == product.id

    {:ok, returned, _} =
      conn |> live("/app/projects/#{project.id}/agent-conversation") |> follow_redirect(conn)

    assert has_element?(returned, "#agent-scroll-#{conversation_id}")
    assert CodeMySpec.Agents.main_agent(scope) == nil

    CodeMySpec.Agents.Presence.untrack(
      self(),
      CodeMySpec.Agents.Presence.topic(project.id),
      product.id
    )

    {:ok, restored, _} =
      live(conn, "/app/projects/#{project.id}/agent-conversation?conversation=#{conversation_id}")

    assert has_element?(restored, "#agent-scroll-#{conversation_id}")
    refute has_element?(restored, "[data-test=product-unavailable]")
    assert CodeMySpec.Agents.present?(scope, product)
  end

  test "a Windows source path stays scoped to its selected device", %{
    conn: conn,
    path: path,
    scope: scope
  } do
    device = CodeMySpec.DevicesFixtures.device_fixture(scope, %{hostname: "windows-desktop"})
    {:ok, view, _} = live(conn, path)

    view
    |> form("#project-definition-form", definition: %{starting_point: "existing"})
    |> render_change()

    view
    |> form("#project-definition-form", definition: %{source_kind: "local"})
    |> render_change()

    windows_path = ~S(C:\Users\person\projects\existing)

    view
    |> form("#project-definition-form",
      definition: %{
        starting_point: "existing",
        source_kind: "local",
        device_id: device.id,
        path: windows_path
      }
    )
    |> render_submit()

    {:ok, project} = Onboarding.fetch(scope)
    assert [%{kind: :local, path: ^windows_path, device_id: id}] = project.sources
    assert id == device.id
  end
end
