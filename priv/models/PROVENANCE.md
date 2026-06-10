# Embedding model provenance

These files back `CodeMySpec.Embeddings.OrtexServing` (a 384-dim
sentence-embedding pipeline). Both ship vendored in this directory and are
loaded from disk at runtime — nothing is fetched over the network, so the
pipeline works fully offline regardless of the host's TLS/CA configuration.

## Files

| File | Role | Loaded by | SHA-256 |
|---|---|---|---|
| `all-MiniLM-L6-v2.onnx` | model weights (ONNX) | `Ortex.load/1` | `6fd5d72fe4589f189f8ebc006442dbb529bb7ce38f8082112682524616046452` |
| `all-MiniLM-L6-v2.tokenizer.json` | WordPiece tokenizer (vocab + rules) | `Tokenizers.Tokenizer.from_file/2` | `be50c3628f2bf5bb5e3a7f17b1f74611b2561a3a27eeab05e5aa30f411572037` |

The `tokenizer.json` is the HuggingFace `tokenizers` fast-format file
(format version `1.0`). It is fully self-describing: it embeds the complete
30,522-token vocab, the 5 special tokens, and the normalizer / pre-tokenizer /
post-processor / decoder. `from_file/2` reads only this one file.

## Source

- Repo: <https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2>
- Revision: `main`
- `tokenizer.json` pulled verbatim from
  `https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/resolve/main/tokenizer.json`

## The matched-pair rule

The `.onnx` weights and `tokenizer.json` are a **matched pair**. The vocab and
tokenization rules must line up with the weights baked into the ONNX graph. If
you ever regenerate or swap the model, re-vendor the matching `tokenizer.json`
**in the same commit** and update the checksums above. They move together or
not at all — a desynced tokenizer corrupts embeddings silently, with no crash.

Do **not** re-introduce a runtime download (`from_pretrained/1` etc.): pulling
`main` at startup re-opens the TLS failure on locked-down hosts and risks
desyncing the tokenizer from this frozen `.onnx`.

## Regenerating the ONNX (reference)

The `.onnx` is a pre-exported version of the upstream PyTorch model. To
reproduce it, export `sentence-transformers/all-MiniLM-L6-v2` to ONNX with the
three inputs the serving expects — `input_ids`, `attention_mask`,
`token_type_ids` (s64) — and a single `last_hidden_state` output; mean-pooling
and L2-normalization are done in Elixir (see `ortex_serving.ex`), not in the
graph. After exporting, drop the matching `tokenizer.json` here and refresh the
checksums.
