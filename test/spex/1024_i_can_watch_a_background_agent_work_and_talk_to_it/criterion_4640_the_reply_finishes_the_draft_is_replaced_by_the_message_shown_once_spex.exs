defmodule CodeMySpecSpex.Story1024.Criterion4640Spex do
  @moduledoc """
  Story 1024 — I can watch a background agent work and talk to it.
  Criterion 4640 — The reply finishes; the draft is replaced by the message,
  shown once.

  Rule: An agent's reply appears as it is written, and becomes the message when
  it is done.

  The draft and the message are two renderings of the same words. A reply shown
  as both — the draft left behind under the message it became — reads as the
  agent saying it twice.
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

  spex "An agent's reply becomes the message when it is done" do
    scenario "The reply finishes; the draft is replaced by the message, shown once" do
      given_ "an agent part-way through a reply I am watching", context do
        copy = CodeMySpec.TempFile.dir("spex_4640")
        RealDisk.mkdir_p!(copy)

        {:ok, _reply, socket} =
          UserSocket
          |> socket("harness_4640", %{scope: context.scope})
          |> subscribe_and_join(HarnessProjectChannel, "harness_project:#{context.project.id}", %{
            "contract_version" => @contract_version,
            "harness_id" => context.scope.active_working_copy_id,
            "root" => copy,
            "label" => "the machine running this agent"
          })

        context = agent_on_held_provider(context, socket, copy)
        {:ok, live, _html} = live(context.conn, context.conversation_path)
        context = Map.put(context, :live, live)

        :ok = reply_part_way(context)

        eventually(fn ->
          assert has_element?(live, "#agent-writing", HeldProvider.reply_so_far()),
                 "the premise is a reply on the page part-way through"
        end)

        {:ok, context}
      end

      when_ "it finishes the reply", context do
        HeldProvider.release()
        await_quiet(context)
        {:ok, context}
      end

      then_ "the page shows the reply as a message", context do
        eventually(fn ->
          refute has_element?(context.live, "#agent-writing"),
                 "the reply finished and the draft is still on the page, beside or " <>
                   "instead of the message it became"
        end)

        assert has_element?(context.live, "[data-test=message]", HeldProvider.whole_reply()),
               "the reply finished and no message carries it"

        {:ok, context}
      end

      then_ "and the reply appears once, not as a draft and a message", context do
        occurrences =
          context.live
          |> render()
          |> String.split(HeldProvider.whole_reply())
          |> length()
          |> Kernel.-(1)

        assert occurrences == 1,
               "the finished reply appears #{occurrences} times on the page — an " <>
                 "operator reads that as the agent saying it more than once"

        {:ok, context}
      end
    end
  end
end
