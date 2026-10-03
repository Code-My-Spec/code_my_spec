defmodule CodeMySpecSpex.Story1046.Criterion3175Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 1182 — A promote reloads the running app by default, and restarts
  it when the change needs a restart, the reload fails, or a restart is asked
  for.

  Rule: The running application must be serving the code that was promoted.

  John (2026-10-02) reversed "always restart": a restart killed every agent
  turn and analysis run on the box for a change the app's own code reloader
  picks up. So a reload is the default, and the paths a reload cannot take —
  deps, config, application.ex, releases, asset deps, the toolchain, MCP tool
  registrations — are one list (`BootVersion.restart_paths/0`) that sends the
  app a restart instead. A reload that fails is not left there: the same
  promote restarts.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import Phoenix.ChannelTest
  import CodeMySpecSpex.PromotionHelpers, only: [a_promotable_story: 1]
  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.McpServers.Promotion.Tools.PromoteSync
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  # The joins go through a real channel, which runs in a process of its own.
  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A code-only change is reloaded, not restarted", criterion: 1182 do
    scenario "the story changes a module and nothing a reload cannot take" do
      given_ "a story branch that changes only a module", context do
        context = a_promotable_project(context)
        write(context.agent_root, "lib/broken_oaths/diplomacy/war.ex", war(":from_the_copy"))
        {_, 0} = git(context, context.agent_root, ["commit", "-q", "-am", "the story's work"])
        {:ok, Map.put(context, :story, a_promotable_story(context))}
      end

      given_ "both copies' analyzers are current", context do
        {:ok, analyzers_are_current(context)}
      end

      when_ "the agent promotes", context do
        response = promote(context, context.story.number)
        answer_app(context.running_socket, "reload_app", "ok")
        {:ok, Map.put(context, :response, response)}
      end

      then_ "the app is reloaded, and the promote says so", context do
        assert response_text(context.response) =~ "Deployment: reload",
               "expected a reload: #{response_text(context.response)}"

        refute_push "restart_app", _, 200
        {:ok, context}
      end
    end
  end

  spex "A change a reload cannot take restarts the app", criterion: 1182 do
    scenario "the story changes compile-time config" do
      given_ "a story branch that changes config", context do
        context = a_promotable_project(context)

        write(
          context.agent_root,
          "config/config.exs",
          "import Config\nconfig :broken_oaths, war: true\n"
        )

        {_, 0} = git(context, context.agent_root, ["add", "-A"])
        {_, 0} = git(context, context.agent_root, ["commit", "-q", "-m", "the story's config"])
        {:ok, Map.put(context, :story, a_promotable_story(context))}
      end

      given_ "both copies' analyzers are current", context do
        {:ok, analyzers_are_current(context)}
      end

      when_ "the agent promotes", context do
        response = promote(context, context.story.number)
        answer_app(context.running_socket, "restart_app", "ok")
        {:ok, Map.put(context, :response, response)}
      end

      then_ "the app is restarted, and the promote names the reason", context do
        text = response_text(context.response)
        assert text =~ "Deployment: restart", "expected a restart: #{text}"

        assert text =~ "config/config.exs",
               "the restart does not say which change needed it: #{text}"

        {:ok, context}
      end
    end
  end

  spex "A reload that fails is followed by a restart", criterion: 1182 do
    scenario "the app does not come back from the reload" do
      given_ "a story branch that changes only a module", context do
        context = a_promotable_project(context)
        write(context.agent_root, "lib/broken_oaths/diplomacy/war.ex", war(":from_the_copy"))
        {_, 0} = git(context, context.agent_root, ["commit", "-q", "-am", "the story's work"])
        {:ok, Map.put(context, :story, a_promotable_story(context))}
      end

      given_ "both copies' analyzers are current", context do
        {:ok, analyzers_are_current(context)}
      end

      when_ "the agent promotes and the reload fails", context do
        _response = promote(context, context.story.number)
        answer_app(context.running_socket, "reload_app", "error")
        {:ok, context}
      end

      then_ "the same promote restarts the app", context do
        answer_app(context.running_socket, "restart_app", "ok")
        {:ok, context}
      end
    end
  end

  # Both copies' analyzers are current.
  #
  # A real precondition, not test scaffolding: the gate will not call a copy
  # clean on an unswept tree, which is criterion 3166. Any scenario about what
  # happens *after* the gate opens has to say that it opens, and this is how a
  # copy says its analyzers have run. 3166 deliberately omits it.
  defp analyzers_are_current(context) do
    CodeMySpecSpex.Fixtures.fresh_analysis_runs(context.scope, ~w(compiler credo exunit spex),
      at_head: true
    )

    CodeMySpecSpex.Fixtures.fresh_analysis_runs(
      %{context.scope | active_working_copy_id: context.running.working_copy_id},
      ~w(compiler credo exunit spex),
      at_head: true
    )

    context
  end

  # Two checkouts of one repository, which is what a promotion actually meets.
  #
  # The application runs from `main` in one checkout; the coding agent works in
  # a worktree of it, on the story's branch. They share an object store, so the
  # running checkout merges the agent's branch by name with no remote involved
  # — and that is the arrangement on John's own machine, where eight worktrees
  # hang off one checkout.
  #
  # Arranged as two real checkouts rather than one, because a promotion that
  # merges into the tree it is promoting *from* is not a promotion, and a spec
  # built on one repository cannot tell the two apart.
  defp a_promotable_project(context) do
    running_root = CodeMySpec.TempFile.dir("spex-1046-running")
    {_, 0} = Environments.cmd(context.environment, "mkdir", ["-p", running_root])

    {_, 0} = git(context, running_root, ["init", "--initial-branch", "main"])
    {_, 0} = git(context, running_root, ["config", "user.email", "spex@example.com"])
    {_, 0} = git(context, running_root, ["config", "user.name", "Spex"])

    write(running_root, "lib/broken_oaths/diplomacy/war.ex", war(":base"))

    # The project's own restart recipe, which is the seam a promotion uses
    # instead of knowing how to bring a Phoenix app up.
    #
    # It compiles before it records, because that is what a real one does — the
    # recipe in this repo runs `mix loadpaths`, `deps.compile` and `ecto.migrate`
    # before it launches anything, and a tree that will not build takes the
    # restart down with it. That is what makes criterion 3168 reachable without
    # an analyzer: a merge that breaks the target is caught here, by the
    # application failing to come back up.
    #
    # `--warnings-as-errors` because a call to a function another module no
    # longer exports is a warning in Elixir, and `just check` in this repo is
    # `mix compile --warnings-as-errors` for exactly that reason.
    write(running_root, "justfile", """
    restart:
        @elixirc -o {{justfile_directory()}}/_spex_build \\
            {{justfile_directory()}}/lib/broken_oaths/diplomacy/*.ex
        @date > {{justfile_directory()}}/.restarted
    """)

    {_, 0} = git(context, running_root, ["add", "-A"])
    {_, 0} = git(context, running_root, ["commit", "-q", "-m", "base"])

    # `worktree add` requires the path not to exist yet.
    agent_root = CodeMySpec.TempFile.dir("spex-1046-agent")
    {_, 0} = Environments.cmd(context.environment, "rm", ["-rf", agent_root])

    {out, 0} =
      git(context, running_root, ["worktree", "add", "-b", "story/war", agent_root, "main"])

    _ = out

    {running, running_socket} =
      join_working_copy_socket(context, running_root, "the checkout the dev app runs in",
        app_verbs: ["reload_app"]
      )

    agent = join_working_copy(context, agent_root, "the coding agent's copy")

    # The running checkout joined first and so holds the designation: the
    # project's first checkout to report a root becomes its main copy
    # (`working_copies.ex:444`). Asserted, because a promotion aimed at a copy
    # that is not main is a promotion to nowhere and every scenario below would
    # pass for the wrong reason.
    {:ok, _view, html} =
      live(context.conn, "/app/projects/#{context.project.id}/working-copies")

    refute html =~
             ~s(phx-value-id="#{running.working_copy_id}" data-test="designate-main-copy"),
           "the premise failed: the running checkout is not this project's main copy"

    context
    |> Map.put(:running_root, running_root)
    |> Map.put(:agent_root, agent_root)
    |> Map.put(:running, running)
    |> Map.put(:running_socket, running_socket)
    |> Map.put(:agent, agent)
    |> Map.put(:scope, %{context.scope | active_working_copy_id: agent.working_copy_id})
  end

  # Through `promote_sync` rather than `promote`.
  #
  # Both doors run the same `Promotion.promote/1`; they differ only in delivery.
  # `promote` is the agent's — it returns at once and messages the outcome back,
  # which is right for minutes of analyzer sweep and wrong for a spec, because
  # there is no outcome in the reply to assert on. `promote_sync` is the door
  # for a caller that has nowhere to be messaged, and it answers.
  defp promote(context, story_number) do
    frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}
    {:reply, response, _frame} = PromoteSync.execute(%{story_number: story_number}, frame)
    response
  end

  # Standing in for the harness on the other end of `verb` (`reload_app` or
  # `restart_app`), answering `status`. Dispatched detached, so the push can
  # arrive a moment after `promote/1` has answered; the timeout is for that gap.
  defp answer_app(socket, verb, status) do
    assert_push ^verb, %{"ref" => ref}, 5_000

    reply_ref =
      Phoenix.ChannelTest.push(socket, verb <> "_result", %{
        "ref" => ref,
        "status" => status,
        "app_status" => "serving",
        "app_url" => "http://127.0.0.1:4000",
        "app_commit" => "cafef00d",
        "error" => "the app did not answer /health"
      })

    receive do
      %Phoenix.Socket.Reply{ref: ^reply_ref, status: :ok} -> :ok
    after
      1_000 -> flunk("#{verb}_result was never acknowledged")
    end
  end

  # An explicit `:cd` wins over the environment's own cwd
  # (`environments/local.ex:217`), which is what lets one environment drive two
  # checkouts.
  defp git(context, dir, args),
    do: Environments.cmd(context.environment, "git", args, cd: dir, stderr_to_stdout: true)

  defp war(body) do
    "defmodule BrokenOaths.Diplomacy.War do\n  def declare, do: #{body}\nend\n"
  end

  # A local environment over the OS temp filesystem, which is where git looks.
  #
  # The suite's own environment fakes the *domain* filesystem while delegating
  # execution to the real one (`environments_behaviour.ex:128`), so a file
  # written through it is invisible to `git` — which is why these checkouts get
  # an environment of their own rather than raw `File`, and why the spex denial
  # on `File` is right rather than something to disable.
  defp disk(root), do: Environment.new(:local, root)

  defp write(root, path, content), do: :ok = Environments.write_file(disk(root), path, content)
end
