defmodule CmsHarnessTest do
  @moduledoc false
  # `CodeMySpec.TempFile` is a leaf boundary with no deps of its own, taken for
  # temp paths that two concurrently running suites cannot both pick. It is the
  # one thing here reaching outside the harness; when the harness moves to its
  # own repo this module goes with it, and a dozen lines of token generation
  # come along rather than the dependency.
  # `Machine` is the only thing spex may reach: they drive a real harness
  # through it rather than referencing `CmsHarness` themselves, which they may
  # not do. Everything else here stays internal to the harness's own tests.
  use Boundary,
    top_level?: true,
    deps: [CmsHarness, CodeMySpec.TempFile],
    exports: [Machine]
end
