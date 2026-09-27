# Security policy

GLB Print Prep processes untrusted 3D files, so parser bugs matter.

## Reporting a vulnerability

Please **do not open a public issue**. Use GitHub's
[private vulnerability reporting](https://github.com/Camponotus-vagus/glb-print-prep/security/advisories/new)
instead. Include a description, the affected version and, if possible, a file that reproduces the problem.

You can expect a first answer within a week. Fixes are released as soon as possible and credited in the
changelog unless you prefer otherwise.

## Scope

- The engine (`engine/`) and the macOS app (`app/`).
- Vulnerabilities in dependencies (glTF-Transform, meshoptimizer, Draco, Node.js) should also be reported
  upstream; we will update the bundled versions.
