defmodule CodeMySpec.EmbeddingsFixtures do
  @moduledoc """
  Test helpers for the embeddings pipeline.

  Production reads bundled framework knowledge from
  `Application.app_dir(:code_my_spec, "priv/knowledge")`. Tests stub
  `:framework_knowledge_dir` to a controlled tmp directory, then need
  to seed/overwrite real files in that directory — this is the one
  spot where a real `File.write!` is the contract under test, since
  `Embeddings.sync_framework_knowledge/1` reads the directory off
  disk on purpose.

  Routing those writes through this fixture keeps the
  `SpexDeniedCalls` credo rule honest — specs don't call `File.*`
  directly, they call this fixture.
  """

  alias CodeMySpec.Embeddings
  alias CodeMySpec.Users.Scope

  @doc """
  Write `content` to `filename` inside the stubbed framework
  knowledge directory. Returns `:ok`.
  """
  @spec write_framework_knowledge_file(String.t(), String.t(), String.t()) :: :ok
  def write_framework_knowledge_file(framework_knowledge_dir, filename, content)
      when is_binary(framework_knowledge_dir) and is_binary(filename) and is_binary(content) do
    File.write!(Path.join(framework_knowledge_dir, filename), content)
  end

  @doc """
  Simulate the file watcher's boot embed pass for framework knowledge.

  In production, `FileWatcherServer.run_boot_embed_pass/1` calls
  `Embeddings.sync_framework_knowledge/1` on watcher startup —
  triggered when the cms binary itself is upgraded and restarts. The
  /files engineer-facing buttons no longer drive this path; the boot
  pass is the always-fresh-after-upgrade surface.

  Specs that need to assert post-upgrade embedding state call this
  helper as the test analog of "the binary restarted with new bundled
  knowledge content."
  """
  @spec simulate_framework_knowledge_boot_embed(Scope.t()) :: :ok
  def simulate_framework_knowledge_boot_embed(%Scope{} = scope) do
    Embeddings.sync_framework_knowledge(scope)
    :ok
  end
end
