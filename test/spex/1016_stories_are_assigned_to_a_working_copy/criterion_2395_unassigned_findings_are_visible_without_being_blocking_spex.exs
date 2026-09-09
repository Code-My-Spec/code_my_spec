defmodule CodeMySpecSpex.Story895.Criterion2395Spex do
  @moduledoc """
  Story 895 — Stories are assigned to a working copy.
  Criterion 2395 — Unassigned findings are visible without being blocking.

  Rule: Only findings on stories assigned to the working copy refuse its stop,
  while those stories' spex have not yet gone green.

  Visibility and enforcement pulled apart, which is the whole design. John:
  *"the working copy should surface all the failures about it, but what we
  should be able to do is say this working copy should be working on these
  stories. It's an assignment problem, not a demotion problem."*

  ## Why not demotion

  Extending attribution demotion to spex was tried and reverted in `ae0a8537`,
  because it left `spex: :block_all` with no effect at all — every finding
  demoted to advisory while the mode read `:block_all` for months, and nothing
  ever blocked. `split_unattributed/2` states the principle: a gate that quietly
  stops blocking is worse than one that blocks too much, because it is
  invisible.

  Assignment does not have that failure mode, and this criterion is the proof
  obligation for that claim. Nothing is hidden. The stop is allowed *and* the
  finding is reported *and* the report says whose story it is — three facts, one
  response, none of them silent.

  ## Its pair

  Criterion 2406 is the other side: once a story's spex have gone green, its
  failures block whoever is stopping, assigned or not. Together they say that
  what earns an exemption here is being unproven work in flight, never merely
  belonging to somebody else.

  Surface: the epic tools (placement), the filesystem (the failure), and the
  stop hook (the decision and what it says).
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.WorkingCopyHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Stories.Tools.AssignEpicToWorkingCopy
  alias CodeMySpec.McpServers.Stories.Tools.AssignStoryToEpic
  alias CodeMySpec.McpServers.Stories.Tools.CreateEpic
  alias CodeMySpec.TempFile
  alias CodeMySpecSpex.RealDisk
  alias Ecto.Adapters.SQL.Sandbox

  @red_fixture_dir "test/fixtures/validation/pipeline_spex_failure"
  @their_label "the other checkout"
  @epic_name "Work that is theirs"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Only findings on stories assigned to the working copy refuse its stop" do
    scenario "Unassigned findings are visible without being blocking" do
      given_ :synced_context_component
      given_ :story_linked_to_component
      given_ :bdd_task_started
      given_ :on_configuration_page

      given_ "spex enforcement is enabled on the project", context do
        # `block_all`, so nothing below is allowed by the mode being lenient.
        # Whatever lets this stop through has to be the story-level rule.
        context.config_live
        |> form("[data-test='configuration-form']", configuration: %{spex: "block_all"})
        |> render_submit()

        {:ok, context}
      end

      given_ "the only outstanding findings are on stories assigned to another working copy",
             context do
        # One story, assigned away, and it is the only thing that fails below —
        # so "the only outstanding findings" is literally true and the allow
        # cannot be coming from something else being clean.
        theirs = join_working_copy(context, "/tmp/spex_2395_their_copy", @their_label)
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, created, _frame} =
          CreateEpic.execute(%{name: @epic_name, description: "Theirs to build"}, frame)

        {:reply, _assigned, _frame} =
          AssignStoryToEpic.execute(
            %{story_id: to_string(context.story.id), epic_name: @epic_name},
            frame
          )

        {:reply, _placed, _frame} =
          AssignEpicToWorkingCopy.execute(
            %{epic_id: epic_id(created), working_copy_id: theirs.working_copy_id},
            frame
          )

        {:ok, context}
      end

      given_ "one of its spex is failing", context do
        [criterion | _] = context.story.criteria
        path = spex_path(context.story, criterion)

        :ok = Environments.write_file(context.environment, path, failing_spex())

        {:ok, Map.put(context, :spex_path, path)}
      end

      when_ "the agent attempts to stop", context do
        response =
          use_cmd_cassette "pipeline_spex_failure", record: :none do
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> post(~p"/api/hooks/stop", %{
              "session_id" => context.session_id,
              "test_output_files" => %{
                "compile" => red_fixture("compile.jsonl"),
                "spex" => spex_jsonl(context.spex_path)
              }
            })
            |> Phoenix.ConnTest.json_response(200)
          end

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the hook allows the stop", context do
        refute context.response["decision"] == "block",
               "the stop was refused over work that belongs to another checkout and has " <>
                 "never been green. Nothing this agent can do clears it: the work is " <>
                 "outside its area, and the latch that would release it is shared state. " <>
                 "Got:\n#{said(context.response)}"

        {:ok, context}
      end

      then_ "and the response still lists those findings as present and assigned elsewhere",
            context do
        said = said(context.response)

        assert said =~ context.spex_path,
               "the stop was allowed and said nothing at all, so the failure is " <>
                 "invisible in the one checkout that saw it. That is demotion by another " <>
                 "name — the `ae0a8537` failure, where a gate quietly stopped mattering " <>
                 "and nobody noticed for months. Got:\n#{said}"

        assert said =~ @their_label,
               "the finding is listed without saying whose it is, so an agent still has " <>
                 "only the discouraging reading available: somebody else's problem, and " <>
                 "no way to tell whether it is holding them up. Got:\n#{said}"

        {:ok, context}
      end
    end
  end

  # Everything the stop hook said back, whichever verdict it reached.
  #
  # A block carries its findings in `reason`; an allow carries what is still
  # true in `systemMessage`. This criterion asserts the verdict *and* what was
  # reported, and those travel in different fields.
  defp said(response) do
    (response["reason"] || "") <> "\n" <> (response["systemMessage"] || "")
  end

  # Where this story's spec for this criterion is expected to live.
  #
  # `test/spex/<number>_<story slug>/criterion_<id>_<criterion slug>_spex.exs`,
  # and it has to be exactly that: the requirement that looks for it names the
  # full path, so a file one slug away is both an unmet requirement (blocking,
  # and not the finding under test) and a spec belonging to no story.
  defp spex_path(story, criterion) do
    "test/spex/#{story.number}_#{slug(story.title)}/" <>
      "criterion_#{criterion.id}_#{slug(criterion.description)}_spex.exs"
  end

  defp slug(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp epic_id(response) do
    response
    |> inspect()
    |> then(&Regex.run(~r/\(ID: ([0-9a-f-]{36})/, &1))
    |> epic_id_match(response)
  end

  defp epic_id_match([_, id], _response), do: id

  defp epic_id_match(nil, response),
    do: flunk("could not read an epic id out of: #{inspect(response)}")

  defp spex_jsonl(path) do
    file = TempFile.path("spex_2395", ".jsonl")

    RealDisk.write!(
      file,
      Jason.encode!(%{
        "spex" => "intentional failure",
        "scenario" => "asserts false",
        "steps" => [%{"type" => "then", "description" => "fails", "status" => "failed"}],
        "error" => %{
          "message" => "spex failure fixture",
          "file" => path,
          "line" => 7,
          "stacktrace" => []
        }
      }) <> "\n"
    )

    file
  end

  defp red_fixture(name), do: Path.expand(Path.join(@red_fixture_dir, name))

  # Well-formed and failing. `ContentCheck` refuses a spec that does not
  # `use <App>Spex.Case` or has a scenario without Given/When/Then, and that
  # refusal is its own blocking finding — which would block this stop for a
  # reason that has nothing to do with assignment.
  defp failing_spex do
    """
    defmodule ExampleContextSpex do
      use ExampleSpex.Case

      spex "intentional failure" do
        scenario "asserts false" do
          given_ "a fixture that is set up", context do
            {:ok, context}
          end

          when_ "the behaviour under test runs", context do
            {:ok, context}
          end

          then_ "it fails", context do
            assert 1 == 2, "spex failure fixture"
            {:ok, context}
          end
        end
      end
    end
    """
  end
end
