defmodule CodeMySpecSpex.Story1057.Criterion3325Spex do
  @moduledoc """
  Story 1057 — The main agent sees the health of the machinery its agents
  depend on.
  Criterion 3325 — Shared machinery is visible across project lines.

  Rule: what you depend on is worth seeing even when you do not own it.

  Every other view the main agent has is scoped to its project, correctly. This
  one has to reach past that, because the harness and the box are shared — and a
  fault in them is a fault in this project's agents regardless of who else is on
  it.

  The reading it prevents is the most confusing one this story can produce: a
  main agent that can see its agents are all stuck, can see nothing wrong with
  anything it owns, and has no way to learn that the machine is carrying two
  other projects' work as well. Every fact it holds is true and the conclusion
  available from them is wrong.

  ## The scope exception is deliberate and bounded

  This is the one place a main agent sees anything outside its project, so the
  boundary is stated rather than assumed: it sees the *machinery* — that the
  harness serves other copies, and what the box is carrying — and not other
  projects' agents, stories or work. Criterion 3326 is the other half: seeing is
  not acting.

  So the scenario asserts both directions. The shared harness has to be visible,
  and the other project's agent must not be.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.CheckMachinery
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The machine is visible even where its other tenants are not" do
    scenario "one machine serves checkouts of two projects" do
      given_ "this project's checkout and another project's on the same device",
             context do
        device = Fixtures.device_fixture(context.scope)

        mine_reply =
          join_working_copy(context, "/tmp/spex-3325-mine", "my checkout", device_id: device.id)

        scope = %{context.scope | active_working_copy_id: mine_reply.working_copy_id}

        Fixtures.record_machine_tools(scope, ["Read", "Write", "Bash"])
        _mine = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-3325-mine")

        # Somebody else's project, on the same box.
        other_scope = Fixtures.other_project_scope(context.scope, "the-other-tenant")

        theirs_reply =
          join_working_copy(
            %{context | scope: other_scope, project: other_scope.active_project},
            "/tmp/spex-3325-theirs",
            "their checkout",
            device_id: device.id
          )

        theirs_scope = %{other_scope | active_working_copy_id: theirs_reply.working_copy_id}

        theirs =
          Fixtures.running_agent(theirs_scope,
            role: "coding",
            working_copy: "/tmp/spex-3325-theirs"
          )

        {:ok,
         context
         |> Map.put(:scope, scope)
         |> Map.put(:device, device)
         |> Map.put(:theirs, theirs)}
      end

      when_ "the main agent looks at the machinery", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = CheckMachinery.execute(%{}, frame)

        refute response.isError, inspect(response)

        {:ok, Map.put(context, :report, response_text(response))}
      end

      then_ "the shared machine is shown", context do
        assert context.report =~ context.device.hostname or
                 context.report =~ ~r/shared|other project|other checkout/i,
               """
               The machine is reported as though this project were the only
               thing on it.

               This is the most confusing reading the story can produce: the
               main agent sees its agents stuck, sees nothing wrong with
               anything it owns, and has no way to learn the box is carrying two
               other projects as well. Every fact it holds is true and the
               conclusion available from them is wrong.

               report:
               #{context.report}
               """

        {:ok, context}
      end

      then_ "and the other project's agents are not", context do
        refute context.report =~ context.theirs.id,
               """
               Another project's agent is named in this project's machinery
               report.

               The scope exception here is the *machinery* — that the harness
               serves other copies, and what the box is carrying — and it stops
               there. A main agent that can read other projects' agents can act
               on them by mistake, and nothing in its own view would tell it
               that it had.

               report:
               #{context.report}
               """

        {:ok, context}
      end
    end
  end
end
