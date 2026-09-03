# Base Image Resolution

The runner deliberately has no default task image. Resolve one from three input
classes: user intent, task capabilities, and target runtime.

## Resolution Order

1. Preserve the user's exact image, tag, Dockerfile, registry, and architecture
   when supplied.
2. Reuse a project-owned Containerfile/Dockerfile when it already represents the
   environment needed by the task.
3. Infer capabilities from manifests and the task: language runtime, compiler,
   browser, database client, CUDA/ROCm, system libraries, and architecture.
4. Prefer a pinned digest or immutable version tag. Avoid `latest`.
5. Ask when choices have meaningful compatibility, size, licensing, GPU, or
   package-manager differences.

## Examples

| Requirement | Candidate class, not an automatic choice |
|---|---|
| Existing application image | Project Dockerfile or published application image |
| Python with uv | Python/uv image matching the lockfile and architecture |
| Node frontend | Node image matching `engines` and lockfile |
| Browser tests | Project Playwright image matching the installed Playwright version |
| NVIDIA training | CUDA/framework image compatible with host driver and project stack |
| CPU-only source review | Minimal image containing the project's required tools |

Do not add CUDA merely because the host has a GPU. Do not choose an x86 image on
Apple Silicon unless emulation is intentional and accepted. Do not replace a
user-selected image to make Codex injection easier; use the thin injection layer
or require a preinstalled Codex image.

## Codex Injection

`layer` copies the pinned Linux Codex native binary from a bootstrap stage into
the selected Linux task image. The task image must provide a POSIX shell, a
compatible Linux libc/runtime for that binary, and the tools required by the
actual task. It does not need Node.js. `build` and `verify` reject an
incompatible result; do not mutate the user's base-image choice merely to make
injection pass.

The Node bootstrap image only extracts the pinned Codex Linux binary during a
multi-stage build. It is not the task base image and none of its filesystem is
retained except the Codex executable set, including version-matched companion
binaries such as `codex-code-mode-host` when the package provides them. It may
be overridden independently for registry or architecture policy.

`preinstalled` does not inject a Codex binary, but it still creates a minimal
derivative control layer with the boundary verifier and owner-contact helper.
Use it only when the selected image already contains the expected Codex CLI
version.
