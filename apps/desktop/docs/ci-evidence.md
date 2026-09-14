# Native CI evidence — 2026-09-14

The [Desktop CI run 34791353523](https://github.com/Yapio-Ltd/mokaid/actions/runs/34791353523)
completed successfully for commit
`d2d5429b17fbed1f069dcefa1ad4c985c0684db0` on the production-delivery PR.
The [application CI run 34791353524](https://github.com/Yapio-Ltd/mokaid/actions/runs/34791353524)
also passed, including API, web, CRM, worker, Terraform, deployment-policy tests
and the four Docker builds with real nginx verification.

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
