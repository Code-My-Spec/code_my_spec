# Story 1112: Windows harness ONNX Runtime

Issue: 484553c1-b8d8-4105-82fd-a46b74dfa540.

The harness release now copies bundled onnxruntime*.dll files from ortex's native directory into erts-*/bin before creating the tarball. It refuses Windows packaging without onnxruntime.dll or a unique ERTS destination. The MSI harvests this release tree. Release Extension downloads Microsoft's ORT 1.19.2 distribution, sets ORT_LIB_LOCATION before compilation, and stages its DLLs beside the NIF before assembly.

## Confirmed workflow failure

GitHub runs 33302694675 (2026-08-30) and 33367437237 (2026-08-31) failed before any Windows build step executed. Check-run annotations 99233631435 and 99410913703 report: The job was not started because an Actions budget is preventing further use. This is separate from the ORT defect and requires an authorized administrator to resolve. No successful workflow execution is claimed.

- https://github.com/Code-My-Spec/code_my_spec/actions/runs/33302694675
- https://github.com/Code-My-Spec/code_my_spec/actions/runs/33367437237

## Validation

Formatting and git diff --check passed. Compiler 58011, ExUnit 58012, and Credo 58013 are pending. Filesystem regression tests cover bundled DLL placement and replacement, companion DLL copying, missing runtime rejection, ambiguous ERTS rejection, and non-Windows behavior. Actionlint is unavailable locally.

## Windows QA

After the Actions budget is resolved, build the changed revision with publish=false. Confirm the Microsoft download and harness release steps pass. Inspect both the tarball and MSI installation for the matching onnxruntime.dll beside erl.exe in erts-*/bin, plus any bundled companion DLLs.

On a disposable Windows machine with Windows ML's older onnxruntime.dll in System32, install and start the harness using the normal MSI flow. Confirm the harness stays running, its health endpoint responds, and logs contain no API-version-19 or Ortex.Native.init panic. Inspect the loaded module path to confirm ORT comes from the installed ERTS directory. Do not remove or replace the System32 DLL to make the test pass.

Filesystem tests do not establish Windows loader behavior. A real Windows build and installed harness boot remain required QA evidence.
