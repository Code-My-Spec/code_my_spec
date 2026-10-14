defmodule CodeMySpec.Requirements.ANarrowLoadReadsItsOwnCheckoutTest do
  @moduledoc """
  A narrow recompute reads the files of the checkout it is computing for.

  `Preloader.load/1` has always done this: two clauses, the scope's own copy
  when it names one and `files_vantage/1` only when it does not. The three
  narrow loaders — `story_context/3`, `load_project/2`, `family_context/3` —
  call `scope_to_harness(files_vantage(scope))` unconditionally, and
  `files_vantage/1` matches on `active_project_id` alone and always answers the
  project's *default* checkout.

  So every narrow recompute computes one checkout's verdicts from main's files.

  ## How it was caught, since a unit test did not find it first

  Issue `78d08d86`, after seven wrong hypotheses. On dev the `devops-q` vantage
  disagreed with the pass about six long-standing components in both directions
  — which staleness cannot produce — and the correlation was six for six:

      component               at main   at devops   rows said
      AnswerNotification         1          0          true
      CallMcpServer              1          0          true
      ListNotifications          1          0          true
      ReadAgentConversation      1          0          true
      AnswerQuestion             0          1          false
      ListOpenQuestions          0          1          false

  The rows' answer tracks main's file state, never the checkout's own.

  ## The ingredient this test needed

  A project with a designated main. Without one `files_vantage/1` answers `nil`,
  `scope_to_harness/2` applies no filter at all, and the bug hides behind a
  different shape. Production always has a default checkout; a fixture does not
  unless it is told to.
  """
  use CodeMySpecSpex.Case, async: true

  alias CodeMySpec.Environments
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Requirements.Preloader
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  @impl_path "lib/example_context.ex"

  describe "a narrow load at a checkout that does not have the file" do
    test "does not see the file the default checkout has", ctx do
      main = ctx.scope

      # Production always has a default checkout. Without this, `files_vantage/1`
      # answers nil and no scoping is applied at all, which hides the bug behind
      # a different shape.
      :ok = Fixtures.designate_main(main, main.active_working_copy_id)

      component =
        CodeMySpec.ComponentsFixtures.component_fixture(main, %{
          name: "ExampleContext",
          module_name: "ExampleContext",
          type: "context"
        })

      :ok =
        Environments.write_file(
          ctx.environment,
          @impl_path,
          "defmodule ExampleContext do\nend\n"
        )

      {:ok, _} = FileSync.sync(main)

      own = Preloader.load_component_family(main, component.id)
      assert paths_in(own) != [], "the default checkout does not see its own file; setup is wrong"

      other = Fixtures.live_agent_scope(main, label: "a checkout without it")
      narrow = Preloader.load_component_family(other, component.id)

      refute @impl_path in paths_in(narrow),
             """
             A narrow recompute for a checkout that does not have this file
             loaded it anyway, from the project's default checkout.

             Every verdict computed from that context is a statement about the
             wrong tree. Four of the six components this was caught on were
             over-satisfied: an agent told the implementation exists because it
             exists in main, and skipping the work.

             loaded: #{inspect(paths_in(narrow))}
             """
    end
  end

  # `fetch!` on the real key. Reading `:files_by_component_role` — which this
  # context does not carry — with a default made an earlier version of this test
  # pass against the very bug it was written to catch.
  defp paths_in({:ok, ctx}), do: paths_in(ctx)

  defp paths_in(ctx) do
    ctx
    |> Map.fetch!(:files_by_component)
    |> Map.values()
    |> List.flatten()
    |> Enum.map(& &1.path)
  end
end
