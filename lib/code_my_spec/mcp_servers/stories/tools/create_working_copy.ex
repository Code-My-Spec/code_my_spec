defmodule CodeMySpec.McpServers.Stories.Tools.CreateWorkingCopy do
  @moduledoc """
  Make a working copy for this project and staff it.

  One call. The harness makes the checkout on its own disk and writes the
  identity into it; the server records the copy and starts the agents that will
  work in it. An agent asking for somewhere to work does not sequence a disk
  operation against a database write — the moment it does, every caller has to
  get the ordering and the failure handling right, and they each get it wrong
  differently.

  Story 891 grew this scope on 2026-09-04. Its question `2ec33878` had asked
  whether onboarding creates the worktree or runs inside one that already
  exists, and answered the second way — so making the copy belonged to nobody.
  Story 956's title says "a minted working copy" and none of its thirteen
  criteria mint anything; 964 hands an epic to a copy and assumes one. A
  project's first epic therefore had nowhere to go but the main checkout, where
  a roster is refused because the main copy holds one agent and it is the
  project's own.

  ## Refused rather than half-made

  A project with no harness connected has no machine to make a checkout on, and
  the answer is a refusal. Writing the row anyway would leave something every
  consumer downstream believes in — the failure `EpicDispatch` had to grow a
  guard against, where the page said "Being built on your project's checkout"
  about a directory that does not exist.

  That is the opposite of what `EpicDispatch.approve/2` does with an epic that
  has nowhere to go, and deliberately: agreeing to build something is a decision
  that survives having nowhere to build it. Asking for a checkout is a request
  for a thing.
  """

  use Anubis.Server.Component, type: :tool

  require Logger

  alias Anubis.Server.Response
  alias CodeMySpec.Agents
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Staffing

  schema do
    field :label, :string,
      description: "What this copy is for, e.g. the epic it will build. Names the directory."

    field :root, :string,
      description:
        "Where to put it. Defaults to a worktree beside the project's checkout; " <>
          "pass one only when it has to go somewhere specific."

    field :roles, :string,
      description:
        "Who to staff it with, comma-separated: main, product, coding, qa. " <>
          "Defaults to product,coding,qa — the three that build something. " <>
          "Name your own when you need a particular shape, e.g. `main` alone."
  end

  @impl true
  def execute(params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} ->
        {:reply, create(scope, params), frame}

      # A sentence, not the bare atom. `inspect(reason)` answered
      # `:no_working_dir`, which names the problem to somebody who already knows
      # the codebase and to nobody else — and this is a tool an agent calls, so
      # the reply is the only thing standing between it and guessing.
      {:error, reason} ->
        {:reply, Response.tool() |> Response.error(scope_refusal(reason)), frame}
    end
  end

  # Delegated. The sequence — ask a machine, record what came back, staff it —
  # lives in `WorkingCopies.mint/2` because it has a second caller with nothing
  # else in common: `EpicDispatch` placing an epic that has nowhere to go. It
  # could not live here, since `McpServers` depends on that context and not the
  # other way round.
  #
  # What stays here is the part that is this tool's: turning the answer into
  # something an agent can read.
  defp create(scope, params) do
    case requested_roles(params[:roles]) do
      {:ok, roles} -> mint(scope, params, roles)
      {:error, message} -> Response.tool() |> Response.error(message)
    end
  end

  defp mint(scope, params, roles) do
    case Staffing.mint(scope, label: params[:label], root: params[:root], roles: roles) do
      {:ok, copy, staffed} -> Response.tool() |> Response.text(report(copy, staffed))
      {:error, reason} -> Response.tool() |> Response.error(refusal(reason))
    end
  end

  # The roster, parsed and checked here rather than passed through.
  #
  # An unknown role reaching `start_copy_agent/4` fails per-role and lands in
  # `failed:`, so a typo would read as "coding could not start" rather than as
  # "there is no role called coading". The list is short and the valid names are
  # worth printing.
  #
  # Why this is settable at all: QA could not test criteria about delivery *to*
  # a main agent, because the only sanctioned way to get disposable agents
  # always staffed exactly product, coding and qa, and the alternatives were
  # reaching into the real project or writing an agent row behind the tool
  # surface (fcbcc3ed). Both defeat the point of a sandbox.
  defp requested_roles(nil), do: {:ok, Agents.copy_roles()}

  defp requested_roles(spec) do
    known = Agents.roles()

    spec
    |> String.split(",", trim: true)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&{&1, Enum.find(known, fn role -> to_string(role) == &1 end)})
    |> Enum.split_with(fn {_given, found} -> found end)
    |> checked(spec, known)
  end

  defp checked({[], _bad}, spec, known),
    do: {:error, "`roles: #{spec}` named none of #{names(known)}."}

  defp checked({_good, [{given, nil} | _]}, _spec, known),
    do: {:error, "There is no `#{given}` role. Pick from #{names(known)}."}

  defp checked({good, []}, _spec, _known),
    do: {:ok, Enum.map(good, fn {_given, role} -> role end)}

  defp names(known), do: Enum.map_join(known, ", ", &to_string/1)

  defp report(copy, %{started: started, failed: []} = staffed) do
    """
    Made a working copy at #{copy.root}.

    id: #{copy.id}
    agents: #{roles(started)}
    #{setup_note(staffed)}
    """
  end

  defp report(copy, %{started: started, failed: failed} = staffed) do
    """
    Made a working copy at #{copy.root}, and it is not fully staffed.

    id: #{copy.id}
    started: #{roles(started)}
    could not start: #{Enum.map_join(failed, ", ", fn {role, reason} -> "#{role} (#{inspect(reason)})" end)}
    #{setup_note(staffed)}
    The copy exists and the work it was made for cannot all be done on it yet.
    """
  end

  # Said here because the agent that asked for the copy is the one about to work
  # in it, and a bare copy fails in ways that do not name their own cause.
  #
  # Measured 2026-09-24 on metric_flow, which has a justfile and no
  # `init-worktree` recipe: the copy arrived with no deps, so the compiler leg
  # reported "cannot satisfy its own mix.lock" and prescribed a `mix deps.get`
  # that fails in a fresh worktree on shallow git deps; no `_build`, so
  # `mix format` died on `Phoenix.CodeReloader`, a Mix listener in the project's
  # own mix.exs; and no dotenv files, so a clean test file read as five broken
  # tests when its own guard clauses flunked. Two agents filed those as framework
  # defects and both were dismissed as environment. None of it was visible from
  # the copy, and the fallback was silent.
  defp setup_note(%{setup: :bare_worktree}) do
    """

    This project declares no `init-worktree` recipe, so the copy is a worktree
    plus submodules, with `deps/` copied and `.env*` files linked from the source
    checkout, and no `_build`. Run `mix deps.compile` there before trusting any
    analyzer or test. Anything else the project keeps untracked is not there, and
    failures from it describe the copy's setup, not your work.
    """
  end

  defp setup_note(_staffed), do: ""

  defp roles([]), do: "none"
  defp roles(agents), do: Enum.map_join(agents, ", ", &to_string(&1.role))

  defp refusal(:no_harness) do
    "No machine is connected for this project, so there is nowhere to make a checkout. " <>
      "A working copy is created on a machine that is running a harness — start one on the " <>
      "machine that holds this project, then ask again. Nothing was recorded."
  end

  defp refusal(:create_timed_out) do
    "The machine did not finish making the checkout in time. It may still be there; nothing " <>
      "has been recorded for it, so this project does not have a working copy at that path."
  end

  defp refusal(reason), do: "The working copy could not be created: #{inspect(reason)}"

  defp scope_refusal(:no_working_dir) do
    "This call names no project, so there is nothing to make a working copy for. " <>
      "The project is resolved from the working directory the call came from. " <>
      "Nothing was created and nothing was recorded."
  end

  defp scope_refusal(reason) do
    "The working copy could not be created because this call has no usable project " <>
      "scope (#{inspect(reason)}). Nothing was created and nothing was recorded."
  end
end
