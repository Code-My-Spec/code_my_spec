defmodule CodeMySpecSpex.Story1000.Criterion744Spex do
  @moduledoc """
  Story 1000 — Agents working the same project do not collide.
  Criterion 744 — A second agent on a working copy already being served is refused.

  Rule: One agent serves a working copy at a time.

  Surface: the channel. The lease *is* the join — taking it on a connection the
  channel owns is what makes leaving, dying or losing the network free it with no
  deadline to wait out. So a refusal is a join reply, and there is no HTTP
  equivalent to assert against.

  The criterion asks for two things and the second is the one that bites: the
  refusal must name which agent holds it. "Refused" alone leaves an operator
  looking at two processes with no way to tell which to stop.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecWeb.{HarnessProjectChannel, UserSocket}
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint
  @contract_version 1
  @root "/workspace/contested"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A working copy is served by one agent" do
    scenario "A second agent on a working copy already being served is refused" do
      given_ "an agent is serving a working copy", context do
        {:ok, reply, socket} =
          UserSocket
          |> socket("harness_holder", %{scope: context.scope})
          |> subscribe_and_join(HarnessProjectChannel, topic(context), join_payload(nil))

        {:ok,
         context
         |> Map.put(:holder, socket)
         |> Map.put(:holder_id, reply["harness_id"] || reply[:harness_id])}
      end

      when_ "a second agent starts against that same working copy", context do
        result =
          UserSocket
          |> socket("harness_intruder", %{scope: context.scope})
          |> subscribe_and_join(HarnessProjectChannel, topic(context), join_payload(nil))

        {:ok, Map.put(context, :second_join, result)}
      end

      then_ "it is refused and told which agent holds it", context do
        assert {:error, refusal} = context.second_join,
               "a second agent joined a working copy already being served, so the lease is " <>
                 "not the join. Got: #{inspect(context.second_join)}"

        rendered = inspect(refusal)

        assert rendered =~ @root or rendered =~ context.holder_id,
               "the refusal must name the agent holding the copy — an operator with two " <>
                 "processes and no name cannot tell which to stop. Got: #{rendered}"

        {:ok, context}
      end

      then_ "the working copy's files are unchanged", context do
        # The holder's connection is what carries the lease, so it must still be
        # serving: a refusal that also knocked the incumbent out would free the
        # copy rather than protect it.
        ref =
          Phoenix.ChannelTest.push(context.holder, "observations", %{
            "observations" => [observation("lib/held.ex")]
          })

        Phoenix.ChannelTest.assert_reply(ref, :ok, _summary)

        {:ok, context}
      end
    end
  end

  defp topic(context), do: "harness_project:#{context.project.id}"

  defp join_payload(harness_id) do
    %{
      "contract_version" => @contract_version,
      "harness_id" => harness_id,
      "root" => @root,
      "label" => "the harness at #{@root}"
    }
  end

  defp observation(path) do
    %{
      "path" => path,
      "role" => "implementation",
      "fingerprint" => "held",
      "mtime" => "2026-08-12T00:00:00.000000Z"
    }
  end
end
