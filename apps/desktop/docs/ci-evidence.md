# Native CI evidence — 2026-09-14

The [Desktop CI run 34799144738](https://github.com/Yapio-Ltd/mokaid/actions/runs/34799144738)
completed successfully for commit
`4996d2c48a2d0229ab29bad09b10ea307d3a17cf` on the production-delivery PR.
The [application CI run 34799144733](https://github.com/Yapio-Ltd/mokaid/actions/runs/34799144733)
also passed, including API, web, CRM, worker, Terraform, deployment-policy tests
and the four Docker builds with real nginx verification.
The [infrastructure CI run 34799144753](https://github.com/Yapio-Ltd/mokaid/actions/runs/34799144753)
passed on that same commit. These runs include the npm/runtime security changes
and four-service staging implementation, but precede the separate Hex corrections.

- Portable: real cooked assets, tests and ASan/UBSan checks passed.
- macOS 15 runner, Xcode 26.3: Qt 6.11.2 installation, C++20 compilation,
  Metal shader build, 13 CTest tests and complete unsigned runtime staging passed.
- Windows 2022 runner, MSVC: Qt 6.11.2 installation, C++20 compilation,
  DXIL vertex/pixel shader builds, 13 CTest tests and complete unsigned runtime
  staging passed. The stage includes the WebEngine subprocess and QML imports.

The verified fixes explicitly align Conan with the checked-in Ninja presets,
select an Xcode libc++ supporting stoppable threads, and use the pinned aqt
upstream fix for Qt 6.11's Windows package layout. No test or release gate was
disabled to obtain this result.

This proves builds and automated tests on hosted runners. It does **not** prove
physical-GPU sharing/synchronization, M1/Iris Xe/NVIDIA performance budgets,
complete product parity, a signed/notarized installer, a trusted installation
on a clean machine, an update between two public versions, or a production
deployment. See the [parity matrix](../application/features/PARITY.md),
[graphics acceptance runbook](../tests/graphics/README.md) and
[release credential checks](release-credentials.md) for those independent obligations.

New commits must pass their own CI. This record is not a waiver allowing a later
commit to inherit a previous commit's successful result.
