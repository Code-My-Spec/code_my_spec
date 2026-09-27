defmodule CodeMySpecSpex.Story1024.Criterion4642Spex do
  @moduledoc """
  Story 1024 — I can watch a background agent work and talk to it.
  Criterion 4642 — A reload after the reply lands shows the message once and no
  draft.

  Rule: An agent's reply appears as it is written, and becomes the message when
  it is done.

  A draft is a preview, never a record. Written down, it would come back on
  every reload beside the message it became; left in the draft store after the
  turn, it would come back as a reply still being written.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers
  import Phoenix.LiveViewTest

  alias CmsHarnessTest.HeldProvider
  alias CodeMySpecSpex.RealDisk
  alias CodeMySpecWeb.{HarnessProjectChannel, UserSocket}
  alias Ecto.Adapters.SQL.Sandbox

  cloud_endpoint()
  @contract_version CodeMySpecWeb.HarnessProjectChannel.contract_version()

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A draft is never kept" do
    scenario "A reload after the reply lands shows the message once and no draft" do
      given_ "an agent that has finished a reply I watched it write", context do
        copy = CodeMySpec.TempFile.dir("spex_4642")
        RealDisk.mkdir_p!(copy)

        {:ok, _reply, socket} =
          UserSocket
          |> socket("harness_4642", %{scope: context.scope})
          |> subscribe_and_join(HarnessProjectChannel, "harness_project:#{context.project.id}", %{
            "contract_version" => @contract_version,
            "harness_id" => context.scope.active_working_copy_id,
            "root" => copy,
            "label" => "the machine running this agent"
          })

        context = agent_on_held_provider(context, socket, copy)
        {:ok, live, _html} = live(context.conn, context.conversation_path)
        :ok = reply_part_way(Map.put(context, :live, live))

        eventually(fn ->
          assert has_element?(live, "#agent-writing", HeldProvider.reply_so_far()),
                 "the premise is a reply I watched being written"
        end)

        HeldProvider.release()
        await_quiet(context)

        eventually(fn ->
          assert has_element?(live, "[data-test=message]", HeldProvider.whole_reply()),
                 "the premise is a reply that has finished"
        end)

        {:ok, context}
      end

      when_ "I reload its conversation", context do
        {:ok, live, html} = live(context.conn, context.conversation_path)
        {:ok, context |> Map.put(:live, live) |> Map.put(:html, html)}
      end

      then_ "the reply appears once, as a message", context do
        occurrences = length(String.split(context.html, HeldProvider.whole_reply())) - 1

        assert occurrences == 1,
               "after a reload the reply appears #{occurrences} times — a draft that " <>
                 "was written down comes back beside the message it became"

        {:ok, context}
      end

      then_ "and no draft is shown", context do
        refute has_element?(context.live, "#agent-writing"),
               "the reply finished before the reload and the page still shows it " <>
                 "being written"

        {:ok, context}
      end
    end
  end
end
