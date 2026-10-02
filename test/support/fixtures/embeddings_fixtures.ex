defmodule CodeMySpec.EmbeddingsFixtures do
  @moduledoc """
  Test helpers for the embeddings pipeline.

  Production reads bundled framework knowledge from
  `Application.app_dir(:code_my_spec, "priv/knowledge")`. Tests stub
  `:framework_knowledge_dir` to a controlled tmp directory, then need
  to seed/overwrite real files in that directory — this is the one
  spot where a real `File.write!` is the contract under test, since
  `FrameworkKnowledgeReconciler` reads the directory off disk on purpose.

  Routing those writes through this fixture keeps the
  `SpexDeniedCalls` credo rule honest — specs don't call `File.*`
  directly, they call this fixture.
  """

  alias CodeMySpec.Embeddings.FrameworkKnowledgeReconciler
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
  Run the server's boot reconcile of framework knowledge.

  Kept for the old story 688 criterion 400 spex, which still calls it; the
  `scope` it takes is unused, as the corpus is shared rows. New spex use
  `server_starts/0`.
  """
  @spec simulate_framework_knowledge_boot_embed(Scope.t()) :: :ok
  def simulate_framework_knowledge_boot_embed(%Scope{}) do
    _ = FrameworkKnowledgeReconciler.reconcile()
    :ok
  end
end
