defmodule CodeMySpecSpex.Story1013.Criterion3098Spex do
  @moduledoc """
  Story 1013 — A working copy comes onto the harness fully configured.
  Criterion 3098 — A copy nothing is serving does not report itself ready.

  Rule: A working copy created this way comes up with its agents already on it.

  The failure path, and the one this whole session started from.

  On 2026-09-04 an agent was started on `broken_oaths/.claude/worktrees/war-epic`.
  Its `.cms_harness.json` was correct — right project, right deploy key,
  `server_url: http://localhost:4000`. The agent row said `starting`. The copy
  was served by nothing, for over an hour, because a harness adopts a copy on its
  **first hook request** (`Projects.ensure_started/1`) and nothing in that
  directory had made one since the harness restarted. The only symptom anybody
  saw was a chat message failing to deliver.

  A freshly created worktree is born into exactly that state. Nobody is sitting
  in the directory to make the first request — that is the point of creating it
  for an agent rather than for a person. So if adoption stays keyed on a hook
  request from inside the copy, every copy this tool makes is unreachable from
  the moment it exists.

  ## What this asserts, and what it leaves open

  That the copy does not *claim* to be ready while nothing is serving it. How
  adoption comes to happen — creation registering the root, the harness
  enumerating its copies, something else — is the implementation's choice. What
  is not its choice is a copy that cannot run work presenting as one that can.

  Story 964's criterion 3088 asserts the same property from the epic side. Two
  criteria on one fact is deliberate here: they fail for different reasons and a
  fix for one does not imply the other.

  ## Red on purpose

  `CreateWorkingCopy` does not exist.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest

  import CodeMySpecSpex.WorkingCopyHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.CreateWorkingCopy
  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  defp created_id(text) do
    case Regex.run(~r/^id: (\S+)/m, text) do
      [_, id] -> id
      _ -> ""
    end
  end

  spex "A working copy created this way comes up with its agents already on it" do
    scenario "A copy nothing is serving does not report itself ready" do
      given_ "a machine holding this project's repository", context do
        copy = join_working_copy(context, "/tmp/spex_3098_host", "the machine with the disk")

        {:ok, Map.put(context, :host, copy.working_copy_id)}
      end

      given_ "a connected provider", context do
        {:ok, _integration} = Fixtures.connect_provider(context.scope, :openai)

        {:ok, context}
      end

      when_ "a checkout has just been created and nothing has made contact from it",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          CreateWorkingCopy.execute(%{label: "nobody is in there yet"}, frame)

        {:ok, _live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/working-copies")

        # That copy's row, not the whole page. The host copy is on it too and is
        # genuinely being served — asserting against the page caught the host and
        # said nothing about the one just created.
        row =
          html
          |> Floki.parse_document!()
          |> Floki.find(~s([data-test="working-copy"][data-working-copy-id="#{created_id(response_text(response))}"]))
          |> Floki.raw_html()

        {:ok, Map.put(context, :row, row)}
      end

      then_ "the copy does not present as ready for work", context do
        refute context.row =~ ~s(data-test="copy-ready"),
               "a copy nothing is serving says it is ready. A worktree made for an " <>
                 "agent has nobody sitting in it to trigger the first hook request, " <>
                 "so if adoption stays keyed on that, every copy this tool makes is " <>
                 "unreachable from the moment it exists."

        {:ok, context}
      end

      then_ "and I do not discover it by sending a message that goes nowhere", context do
        assert context.row =~ ~s(data-test="copy-not-ready"),
               "the page says nothing either way, so the first thing that tells " <>
                 "anybody is a chat message failing to deliver — which is how this " <>
                 "was found, an hour after it started."

        {:ok, context}
      end
    end
  end
end
