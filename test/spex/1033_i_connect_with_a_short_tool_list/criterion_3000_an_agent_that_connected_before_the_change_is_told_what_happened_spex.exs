defmodule CodeMySpecSpex.Story1033.Criterion3000Spex do
  @moduledoc """
  Story 1033 — I connect with a short tool list
  Criterion 3000 — An agent that connected before the change is told what happened

  A tool list is cached at connect, so every session that joined before this
  landed still holds all 111 names and will call one that is no longer
  advertised. The honest answer is not "no such tool" — the tool exists, it
  moved, and the agent is one call from it.

  Asserted on the reply as the transport receives it. An earlier version
  called `Response.to_protocol/1` on it here, which was the conversion the
  server had skipped — the spec did the server's job and passed either way.
  When the server was fixed to convert, this spec broke, which is the right
  way round but for the wrong reason: it should never have been converting.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.{LocalServer, ScriptableTools}

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "I connect with a short tool list" do
    scenario "An agent that connected before the change is told what happened" do
      given_ "a tool that has moved to code mode", context do
        moved = ScriptableTools.__components__() |> hd() |> Map.get(:name)

        refute moved in MapSet.new(LocalServer.__components__(), & &1.name)

        {:ok, Map.put(context, :moved, moved)}
      end

      when_ "a session holding the old list calls it", context do
        request = %{
          "method" => "tools/call",
          "params" => %{"name" => context.moved, "arguments" => %{}}
        }

        {:reply, reply, _frame} = LocalServer.handle_request(request, %Frame{})

        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "it is told the tool moved and how to reach it", context do
        text = context.reply |> Map.get("content") |> hd() |> Map.get("text")

        assert text =~ "code mode"
        assert text =~ "run_script"
        {:ok, context}
      end

      then_ "and is not told the tool does not exist", context do
        text = context.reply |> Map.get("content") |> hd() |> Map.get("text")

        refute text =~ "not found",
               "the agent would go looking for a name that is not wrong"

        {:ok, context}
      end

      then_ "and the reply is something the transport can actually send", context do
        # The bug this criterion nearly shipped with: a struct here does not
        # fail the call, it terminates the session.
        assert {:ok, _json} = Jason.encode(context.reply)
        {:ok, context}
      end
    end
  end
end
