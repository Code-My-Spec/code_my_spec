defmodule CmsHarness.ProjectIdentity do
  @moduledoc """
  Which project a directory is.

  The server used to answer this by looking a filesystem path up in its own
  database, which is precisely the question a server with no disk cannot
  answer. So the harness answers it, locally, and the server only ever receives
  an id.

  Resolution order:

    1. `project_id` in the working copy's own `.code_my_spec/config.yml`
    2. `project_id` in the working copy's own `.cms_harness.json`
    3. `CMS_PROJECT_ID` — for a copy that names no project, which is a sprite
    4. refuse

  There is no fifth step. A directory that cannot say which project it is gets
  an error naming the file it should have said it in, because guessing here
  means syncing one checkout's files over another project's rows.

  ## Step 2, and why the env fallback had to be narrowed to reach it

  `.cms_harness.json` is what `mix cms.harness.onboard` writes, and it carries
  `project_id` as well as `harness_id`. Only the second was ever read here, so
  a working copy that was properly onboarded but never given a
  `.code_my_spec/config.yml` fell straight past its own answer to the variable.

  Measured 2026-08-21 from `harness.log`, on this machine. One daemon serving
  three roots:

      serving project 708492f9-… at …/broken_oaths
      serving project 708492f9-… at …/code_my_spec
      serving project 708492f9-… at …/code_my_spec/.claude/worktrees/phx-new-generator

  `broken_oaths` is a different repository. Its `.cms_harness.json` says
  `49760b8b-…`; the daemon carried `CMS_PROJECT_ID=708492f9-…` from the session
  that started it, and with no `config.yml` to read, the variable won. So its
  files reconciled into CodeMySpec's project and its spex runs answered
  CodeMySpec's spex requests. The trail is 96 warnings reading `could not read
  spec file .code_my_spec/spec/broken_oaths/technology/research.spec.md
  (:enoent)` — a row written from one checkout, looked for in another.

  This is the same defect the section below describes, at the same call site,
  one field over: `harness_id(:env, root)` was taught to check the file first
  and `project_id` was not, so the narrower half of the identity was safe while
  the half that decides *which project's rows get written* was not.

  ## The file wins, and it did not used to

  `CMS_PROJECT_ID` was first and won outright, on the reasoning that a sprite
  sets it and a sprite is the whole VM. That reasoning is sound about a sprite
  and wrong about everything else, because this function is called **once per
  working copy** — `Projects.ensure_started/1` resolves every root the harness
  serves through it — while the variable is a property of whatever launched the
  daemon. A harness started from an agent session in a CodeMySpec checkout
  inherits that session's `CMS_PROJECT_ID`, and then *every* root it serves
  answers with that one project no matter what its config says.

  Measured 2026-08-20: a scratch working copy whose `config.yml` named
  `11111111-1111-4111-8111-111111111111` minted a harness against
  `708492f9-…` — the id exported in the session that ran the command — with
  nothing in the output naming the substitution.

  This is the same shape as the harness-id collapse that produced the JOIN/CLOSE
  loop the night before, one layer up and with a worse consequence: identity
  decides which project's rows a checkout's files are written to. Story 1000's
  criterion 737 states the rule outright — "an agent learns which project it
  serves from its identity, not from its environment" — and its own comment
  names this exact scenario: "a developer working two projects in two terminals
  has exactly that variable set, and an agent that read it would write one
  project's files into the other's rows with nothing suspicious in any log."
  That criterion drives the hook endpoint, where the project comes from the
  harness record, so it could not see this path.

  A sprite is unaffected: its checkout carries no `.code_my_spec/config.yml` of
  its own, so step 1 finds nothing and the variable answers — which is what
  step 2 is for. When both are present and *disagree*, the file wins and the
  disagreement is logged rather than swallowed; it is a misconfiguration, and a
  container that refused to start over it would be much harder to diagnose from
  the inside than one that says which of the two it chose.

  `Projects.resolve_local_project/1` on the server keeps env-first and is
  **not** the same question. It reads `Application.get_env(:code_my_spec,
  :project_id)` — an install-level setting, not an inherited shell variable —
  and every one of its callers passes `nil` or a single boot-time directory,
  because the packaged CLI serves one project per VM. One-copy-per-VM is the
  case env-first is right for. This module is the other one.
  """

  require Logger

  alias CmsHarness.HarnessConfig

  @config_path ".code_my_spec/config.yml"

  @type t :: %{id: String.t(), root: String.t(), harness_id: String.t() | nil}

  @doc """
  Resolve the project id for a working directory.

  `root` is normalised to an absolute path so two spellings of the same
  checkout cannot start two subtrees against one project.
  """
  @spec resolve(String.t()) ::
          {:ok, t()} | {:error, :no_project_id | :unreadable_config | {:invalid_config, term()}}
  def resolve(root) when is_binary(root) do
    root = Path.expand(root)

    with {:ok, source, project} <- resolve_project(root) do
      {:ok, Map.put(project, :harness_id, harness_id(source, root))}
    end
  end

  defp resolve_project(root) do
    case from_config(root) do
      {:ok, project} -> note_disagreement(project, :config)
      {:error, :no_project_id} -> from_harness_file(root)
      {:error, reason} -> {:error, reason}
    end
  end

  # The other file the working copy names itself in, and the one onboarding
  # actually writes. Read before the variable for the reason the whole module
  # exists: this runs once per root, and the variable belongs to whatever
  # started the daemon.
  defp from_harness_file(root) do
    case HarnessConfig.read_file(root) do
      {:ok, %{project_id: id}} when is_binary(id) and id != "" ->
        note_disagreement(%{id: id, root: root}, :harness_file)

      _ ->
        from_env(root)
    end
  end

  # A copy that names no project in either file falls through to the variable.
  # That is the sprite: one VM, one project, no config of its own to read.
  defp from_env(root) do
    case System.get_env("CMS_PROJECT_ID") do
      id when is_binary(id) and id != "" -> {:ok, :env, %{id: id, root: root}}
      _ -> {:error, :no_project_id}
    end
  end

  # The file wins; saying so is `log_env_disagreement/1`'s job, not this one's.
  #
  # It used to log here, and this runs once per working copy *per resolution* —
  # every hook, every operation. A permanent disagreement therefore said itself
  # forever: 787 identical warnings in two hours on one machine, where the
  # daemon carried one project's `CMS_PROJECT_ID` and served another project's
  # checkout. That is the shape that trains a reader past the whole channel,
  # which is the opposite of what a misconfiguration warning is for.
  defp note_disagreement(project, source), do: {:ok, source, project}

  @doc false
  # Said once, where a working copy is taken up rather than where its identity is
  # read. `Projects.ensure_started/1` reaches its serving branch once per root
  # per daemon, which is the rate this fact actually changes at.
  #
  # Logged rather than refused, unchanged: a daemon that would not start over a
  # variable it inherited is far harder to diagnose from the inside than one that
  # starts and names which of the two it took.
  @spec log_env_disagreement(t()) :: :ok
  def log_env_disagreement(%{id: id, root: root}) do
    case System.get_env("CMS_PROJECT_ID") do
      other when is_binary(other) and other != "" and other != id ->
        Logger.warning(
          "[CmsHarness] #{root} says it is project #{id} (#{file_naming(root)}) and " <>
            "CMS_PROJECT_ID says #{other}. Serving #{id} — the working copy's own file " <>
            "wins, because one harness serves several copies and the variable belongs to " <>
            "whatever started it."
        )

      _ ->
        :ok
    end
  end

  # Which of the copy's two identity files answered, so the reader knows which
  # one to go and fix.
  defp file_naming(root) do
    case from_config(root) do
      {:ok, _project} -> @config_path
      _ -> ".cms_harness.json"
    end
  end

  # `nil` means "not issued yet", which is ordinary — the first join mints it.
  # An unreadable config also reads as `nil` here, but `HarnessConfig.write/2`
  # refuses to overwrite one, so the stranding that would cause is contained to
  # the one session rather than made permanent.
  #
  # **The file wins for both sources, and only `:env` falls further.** A copy
  # whose project came from its own `config.yml` takes its harness id from its
  # own file and nothing else — no working copy with a real config gets to
  # borrow another one's exported id. A copy with no config to read might still
  # be a real, already-onboarded working copy rather than a fresh sprite — it
  # just never got a `.code_my_spec/config.yml` of its own — so `:env` checks
  # the file first too, via the same `HarnessConfig.read/1` a single-root
  # resolution always uses, and only falls through to `CMS_HARNESS_ID` when
  # there is truly no file to read.
  #
  # Checking the environment first here, unconditionally, was the bug:
  # measured 2026-08-20 on a real working copy — onboarded, with its own
  # correct `.cms_harness.json`, but never given a `config.yml` — every join
  # presented the *launching session's* harness id instead of its own,
  # because that was checked before the file that actually named it.
  defp harness_id(:env, root) do
    case HarnessConfig.read(root) do
      {:ok, %{harness_id: id}} -> id
      _ -> nil
    end
  end

  defp harness_id(:config, root), do: from_harness_config(root)

  defp harness_id(:harness_file, root), do: from_harness_config(root)

  defp from_harness_config(root) do
    case HarnessConfig.read_file(root) do
      {:ok, %{harness_id: id}} -> id
      _ -> nil
    end
  end

  @doc "The path the id is expected to live in, for error messages."
  @spec config_path(String.t()) :: String.t()
  def config_path(root), do: Path.join(Path.expand(root), @config_path)

  defp from_config(root) do
    path = config_path(root)

    with {:ok, contents} <- read(path),
         {:ok, parsed} <- parse(contents),
         id when is_binary(id) and id != "" <- to_string_id(parsed["project_id"]) do
      {:ok, %{id: id, root: root}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :no_project_id}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, :enoent} -> {:error, :no_project_id}
      {:error, _} -> {:error, :unreadable_config}
    end
  end

  defp parse(contents) do
    case YamlElixir.read_from_string(contents) do
      {:ok, %{} = parsed} -> {:ok, parsed}
      {:ok, _} -> {:error, {:invalid_config, :not_a_mapping}}
      {:error, reason} -> {:error, {:invalid_config, reason}}
    end
  end

  # YAML gives an integer for `project_id: 712`; the topic is a string either
  # way. Normalising here means the channel client never has to care.
  defp to_string_id(id) when is_integer(id), do: Integer.to_string(id)
  defp to_string_id(id) when is_binary(id), do: String.trim(id)
  defp to_string_id(_), do: nil
end
