defmodule CodeMySpecSpex.Story1112.Criterion2035Spex do
  @moduledoc """
  Story 1112: a fresh desktop installation checks the machine prerequisites
  and leaves their results in a file. Only external command-line programs
  are fixtures; the desktop UI and setup runner must execute the real flow.
  The results path is obtained from the UI rather than prescribing its location.
  """
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.DesktopSetupHelpers

  setup :fresh_machine

  defp fresh_machine(context), do: DesktopSetupHelpers.fresh_machine(context)

  spex "Desktop setup checks and records every development prerequisite", criterion: 2035 do
    scenario "A fresh installation runs the checks and writes their results" do
      given_ "a machine with the desktop app just installed", context do
        {:ok, view, _html} = live(context.conn, "/app")
        {:ok, Map.put(context, :view, view)}
      end

      when_ "the developer checks prerequisites in desktop setup", context do
        context.view
        |> element("[data-test='check-prerequisites']")
        |> render_click()

        render_async(context.view, 10_000)
        {:ok, context}
      end

      then_ "commands check Postgres, pgvector, the managed Erlang/Elixir toolchain, cms and Vibium",
            context do
        commands = read_machine_file!(context, context.command_log)
        assert commands =~ ~r/^psql /m
        assert commands =~ ~r/^psql .*vector/m
        assert commands =~ ~r/^(mise|asdf) /m
        assert commands =~ ~r/^(elixir .*--version|(mise|asdf) .*elixir)/m
        assert commands =~ ~r/^(erl |elixir .*--version|(mise|asdf) .*erlang)/m
        assert commands =~ ~r/^cms /m
        assert commands =~ ~r/^vibium /m
        {:ok, context}
      end

      then_ "each check result is written to the setup results file named in the app", context do
        assert has_element?(context.view, "[data-test='setup-results-file'][data-path]")

        [path] =
          context.view
          |> element("[data-test='setup-results-file']")
          |> render()
          |> Floki.parse_fragment!()
          |> Floki.attribute("data-path")

        assert String.starts_with?(Path.expand(path), context.machine_root <> "/")
        assert {:ok, results} = Environments.read_file(context.machine_environment, path)
        assert results =~ ~r/postgres/i
        assert results =~ ~r/(pgvector|vector)/i
        assert results =~ ~r/erlang/i
        assert results =~ ~r/elixir/i
        assert results =~ ~r/cms/i
        assert results =~ ~r/vibium/i
        assert results =~ "16.4"
        assert results =~ "0.8.0"
        assert results =~ "1.18.1"
        assert results =~ "2.0.0"
        assert results =~ "1.0.0"
        {:ok, context}
      end
    end
  end

  defp read_machine_file!(context, path) do
    {:ok, contents} = Environments.read_file(context.machine_environment, path)
    contents
  end
end
