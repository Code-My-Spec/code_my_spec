defmodule CodeMySpecSpex.RemotePromotionHelpers do
  @moduledoc """
  Real bare-origin promotion scenarios driven through the agent's promote tool.
  Analyzer and QA evidence are fixture preconditions, covered by the gate/QA
  specs; the queue, publication, Git transport, and agent outcome are real.
  """
  import ExUnit.Assertions
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.ExecutionContexts.ExecutionContext
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.PromotionHelpers, as: Promotion

  @endpoint CodeMySpecWeb.Endpoint

  def remote_project(context, branch \\ "main") do
    Promotion.stop_the_queue_on_exit(context.project.id)
    dir = CodeMySpec.TempFile.owned_dir("spex-remote-promotion")
    origin = Path.join(dir, "origin.git")
    source = Path.join(dir, "source")
    gate_root = Path.join(dir, "gate")
    git!(dir, ["init", "--bare", "--initial-branch=main", origin])
    git!(dir, ["clone", origin, source])
    git!(source, ["config", "user.email", "spex@example.com"])
    git!(source, ["config", "user.name", "Spex"])

    Promotion.write(
      source,
      "lib/example.ex",
      "defmodule Example do\n  def value, do: :base\nend\n"
    )

    git!(source, ["add", "."])
    git!(source, ["commit", "-m", "base"])
    git!(source, ["push", "origin", "main"])
    base = git!(source, ["rev-parse", "HEAD"])
    prepare_branch(source, branch)
    git!(source, ["checkout", "-b", "story/remote"])
    device = Fixtures.device_fixture(context.scope)

    {agent, socket} =
      Promotion.join_local_working_copy_socket(context, source, "cloud source",
        device_id: device.id
      )

    git!(source, ["worktree", "add", "--detach", gate_root, branch])

    {gate, gate_socket} =
      Promotion.join_local_working_copy_socket(
        context,
        gate_root,
        "promotion-gate:#{agent.working_copy_id}",
        device_id: device.id
      )

    context
    |> Map.merge(%{
      origin: origin,
      agent_root: source,
      agent: agent,
      agent_socket: socket,
      gate_root: gate_root,
      gate: gate,
      gate_socket: gate_socket,
      base: base,
      branch: branch,
      scope: %{context.scope | active_working_copy_id: agent.working_copy_id}
    })
    |> Promotion.an_agent_on_the_copy()
  end

  defp prepare_branch(_source, "main"), do: :ok

  defp prepare_branch(source, branch) do
    git!(source, ["branch", branch])
    git!(source, ["push", "origin", branch])
  end

  def choose_branch(context, branch) do
    {:ok, view, _} = live(context.conn, "/app/projects/#{context.project.id}/edit")
    view |> form("#project-form", project: %{development_branch: branch}) |> render_submit()
    {:ok, view, _} = live(context.conn, "/app/projects/#{context.project.id}/edit")
    assert has_element?(view, "input[name='project[development_branch]'][value='#{branch}']")
    context
  end

  def verified_candidate(context) do
    Promotion.write(
      context.agent_root,
      "lib/example.ex",
      "defmodule Example do\n  def value, do: :candidate\nend\n"
    )

    git!(context.agent_root, ["add", "lib/example.ex"])
    git!(context.agent_root, ["commit", "-m", "candidate"])
    story = Promotion.a_promotable_story(context)
    Fixtures.fresh_analysis_runs(context.scope, ~w(compiler credo exunit spex), at_head: true)

    Map.merge(context, %{story: story, candidate: git!(context.agent_root, ["rev-parse", "HEAD"])})
  end

  def request_publication(context) do
    response = Promotion.promote(context, context.story.number)
    refute response.isError, inspect(response)
    Map.put(context, :response, response)
  end

  def outcome(%{agent_id: agent_id, gate_socket: %{join_ref: gate_ref}} = context) do
    receive do
      {:agent_dispatch, ^agent_id, _ref, message} ->
        Map.put(context, :outcome, message)

      %Phoenix.Socket.Message{event: "run_analysis", join_ref: ^gate_ref} = request ->
        send(self(), request)
        context |> Promotion.the_gate_answers() |> outcome()
    after
      30_000 -> flunk("the promoting agent was never told what became of its promotion")
    end
  end

  def require_gate(context) do
    other = Path.join(Path.dirname(context.origin), "new-origin-work")
    git!(Path.dirname(context.origin), ["clone", context.origin, other])
    git!(other, ["config", "user.email", "other@example.com"])
    git!(other, ["config", "user.name", "Other"])
    git!(other, ["checkout", context.branch])
    Promotion.write(other, "other.txt", "Already published independent work\n")
    git!(other, ["add", "other.txt"])
    git!(other, ["commit", "-m", "independent work"])
    git!(other, ["push", "origin", context.branch])
    context
  end

  def await_gate(context) do
    assert Promotion.the_gate_is_running(context) == ~w(compiler credo exunit spex)
    context
  end

  def reject_push(context) do
    hook(context.origin, "hooks/pre-receive", "echo policy-rejected >&2\nexit 1\n")
    context
  end

  def lose_push_response(context) do
    wrapper = hook(context.origin, "lose-response", "git-receive-pack \"$@\"\nexit 1\n")
    git!(context.agent_root, ["config", "remote.origin.receivepack", wrapper])
    context
  end

  def concurrent_landing(context) do
    competitor = Path.join(Path.dirname(context.origin), "competitor")
    git!(Path.dirname(context.origin), ["clone", context.origin, competitor])
    git!(competitor, ["config", "user.email", "other@example.com"])
    git!(competitor, ["config", "user.name", "Other"])
    Promotion.write(competitor, "other.txt", "Another engineer's work\n")
    git!(competitor, ["add", "other.txt"])
    git!(competitor, ["commit", "-m", "competing work"])
    head = git!(competitor, ["rev-parse", "HEAD"])
    git!(competitor, ["push", "origin", "HEAD:refs/heads/competing"])
    marker = Path.join(context.origin, "competed")

    hook(
      context.agent_root,
      ".git/hooks/pre-push",
      "if [ ! -e '#{marker}' ]; then\ngit --git-dir='#{context.origin}' update-ref refs/heads/#{context.branch} '#{head}' '#{context.base}'\ntouch '#{marker}'\nfi\n"
    )

    Map.put(context, :competitor, head)
  end

  def gate_answers(context), do: Promotion.the_gate_answers(context)

  def remote_head(context),
    do: git!(context.origin, ["rev-parse", "refs/heads/#{context.branch}"])

  def git!(root, args) do
    {output, status} =
      ExecutionContexts.cmd(ExecutionContext.new(:local, root), "git", args,
        cd: root,
        stderr_to_stdout: true
      )

    assert status == 0, output
    String.trim(output)
  end

  defp hook(root, path, body) do
    Promotion.write(root, path, "#!/bin/sh\n" <> body)
    full = Path.join(root, path)
    File.chmod!(full, 0o755)
    full
  end
end
