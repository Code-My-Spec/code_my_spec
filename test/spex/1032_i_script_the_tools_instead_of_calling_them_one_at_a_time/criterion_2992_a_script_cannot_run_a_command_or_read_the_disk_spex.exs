defmodule CodeMySpecSpex.Story1032.Criterion2992Spex do
  @moduledoc """
  Story 1032 — I script the tools instead of calling them one at a time
  Criterion 2992 — A script cannot run a command or read the disk

  Asserted on the *call*, not on the name. `Lua.new/1` sandboxes by replacing
  a function with one that raises, so `io` is still a table and asserting
  `io == nil` would pass against a VM where `io.open` works fine.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.CodeMode.Tools.RunScript

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "I script the tools instead of calling them one at a time" do
    scenario "A script cannot run a command or read the disk" do
      given_ "the agent is connected to its project", context do
        {:ok, Map.put(context, :frame, %Frame{assigns: %{current_scope: context.scope}})}
      end

      when_ "the script tries to run a command and open a file", context do
        script = ~S"""
        local _, shell = pcall(os.execute, "echo pwned")
        local _, disk = pcall(io.open, "/etc/passwd", "r")
        return shell .. "|" .. disk
        """

        {:reply, response, _frame} = RunScript.execute(%{script: script}, context.frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "both are refused as sandboxed", context do
        text = response_text(context.response)

        assert text =~ "os.execute"
        assert text =~ "io.open"
        assert text =~ "sandboxed"
        {:ok, context}
      end
    end
  end
end
