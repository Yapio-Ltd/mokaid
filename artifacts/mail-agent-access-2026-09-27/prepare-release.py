#!/usr/bin/env python3
"""Prepare the isolated Mail-agent release. This script does not build or deploy.

Run only after the API/worker owners declare their sources and tests stable.
The previous 51-file Mail-center overlay is always read from its frozen release,
never reconstructed from the shared working tree.
"""

from pathlib import Path, PurePosixPath
import hashlib
import io
import json
import os
import shutil
import subprocess
import tarfile
import tempfile


SOURCE = Path('/Users/olimservice/mokaid')
TARGET = Path('/private/tmp/mokaid-mail-agents-release-20260927')
PREVIOUS = Path('/private/tmp/mokaid-mail-center-release-20260927')
PREVIOUS_MANIFEST = SOURCE / 'artifacts/mail-center-2026-09-27/snapshot-source-manifest.json'
BASE = '4716998a35123c85e19bdbe2013e8f4ff3d69669'
EXPECTED_DEPLOYED_API = 58
EXPECTED_DEPLOYED_WORKER = 51
MAIN = 'apps/ai-worker/app/main.py'

# Explicit allowlist. No dispatcher/Jev source or tests, web or native changes.
# main.py is generated separately from the previous frozen overlay below.
CURRENT_FILES = '''
apps/ai-worker/app/agents/deep_runner.py
apps/ai-worker/app/agents/direct_chat.py
apps/ai-worker/app/agents/managed_runner.py
apps/ai-worker/app/agents/mission_kind.py
apps/ai-worker/app/agents/orchestrator_chat.py
apps/ai-worker/app/agents/planner.py
apps/ai-worker/app/agents/quality.py
apps/ai-worker/app/agents/runner.py
apps/ai-worker/app/agents/runtime.py
apps/ai-worker/app/clients/phoenix.py
apps/ai-worker/app/policies/approval.py
apps/ai-worker/app/schemas.py
apps/ai-worker/app/tools/mail.py
apps/ai-worker/app/tools/registry.py
apps/ai-worker/tests/test_direct_chat.py
apps/ai-worker/tests/test_mail_mission_routing.py
apps/ai-worker/tests/test_orchestrator_chat.py
apps/ai-worker/tests/test_runner.py
apps/ai-worker/tests/test_workspace_mail_tools.py
apps/api/lib/mokaid/ai/coordinator.ex
apps/api/lib/mokaid/ai/managed_runtime.ex
apps/api/lib/mokaid/ai/orchestrator.ex
apps/api/lib/mokaid/ai/workers/agent_chat_worker.ex
apps/api/lib/mokaid/ai/workers/dispatch_worker.ex
apps/api/lib/mokaid/mail/agent_access.ex
apps/api/lib/mokaid/mail/agent_tools.ex
apps/api/lib/mokaid/tasks.ex
apps/api/lib/mokaid_web/controllers/worker_mail_tools_controller.ex
apps/api/lib/mokaid_web/router.ex
apps/api/test/mokaid/dispatch_worker_test.exs
apps/api/test/mokaid/mail_agent_access_test.exs
apps/api/test/mokaid/mail_agent_tools_test.exs
apps/api/test/mokaid/orchestrator_test.exs
apps/api/test/mokaid_web/orchestrator_controller_test.exs
apps/api/test/mokaid_web/worker_mail_tools_controller_test.exs
'''.split()

ARCHIVE_PATHS = [
    'apps/api', 'apps/ai-worker', 'apps/desktop/tools/asset-cooker',
    'infra/docker', '.dockerignore', '.github/scripts/ecs_deploy.py',
]


def sha256(raw):
    return hashlib.sha256(raw).hexdigest()


def source_bytes(root, name):
    path = PurePosixPath(name)
    if path.is_absolute() or '..' in path.parts or not name.startswith(('apps/api/', 'apps/ai-worker/')):
        raise RuntimeError(f'Unexpected overlay path: {name}')
    candidate = root / name
    candidate.resolve(strict=True).relative_to(root.resolve(strict=True))
    if candidate.is_symlink() or not candidate.is_file():
        raise RuntimeError(f'Expected regular source file: {name}')
    return candidate.read_bytes()


def isolated_main(previous):
    text = previous.decode('utf-8')
    anchor = 'import app.tools.files  # noqa: F401 — registers file-processing tools\n'
    addition = 'import app.tools.mail  # noqa: F401 — workspace-scoped mailbox tools\n'
    old_timeout = 'await asyncio.wait_for(orchestrator_chat.respond(payload), timeout=22)'
    new_timeout = 'await asyncio.wait_for(orchestrator_chat.respond(payload), timeout=55)'
    if text.count(anchor) != 1 or addition in text or text.count(old_timeout) != 1:
        raise RuntimeError('Frozen main.py no longer matches the two reviewed Mail-agent edits')
    updated = text.replace(anchor, anchor + addition, 1).replace(old_timeout, new_timeout, 1)
    # Prove that removing only the two allowed changes reproduces the previous file.
    restored = updated.replace(addition, '', 1).replace(new_timeout, old_timeout, 1)
    if restored.encode('utf-8') != previous:
        raise RuntimeError('Unexpected main.py change')
    return updated.encode('utf-8')


def prepare():
    if TARGET.exists():
        raise RuntimeError(f'Refusing to overwrite a prepared release: {TARGET}')
    manifest_raw = PREVIOUS_MANIFEST.read_bytes()
    previous_manifest = json.loads(manifest_raw)
    if previous_manifest.get('base') != BASE:
        raise RuntimeError('Previous snapshot uses another base commit')
    previous_hashes = previous_manifest.get('files')
    if not isinstance(previous_hashes, dict) or len(previous_hashes) != 51:
        raise RuntimeError('Expected exactly 51 previously validated overlays')
    if len(CURRENT_FILES) != 35 or len(set(CURRENT_FILES)) != 35 or MAIN in CURRENT_FILES:
        raise RuntimeError('The explicit current-source allowlist changed unexpectedly')

    previous_bytes = {}
    for name, expected in sorted(previous_hashes.items()):
        raw = source_bytes(PREVIOUS, name)
        if sha256(raw) != expected:
            raise RuntimeError(f'Previously validated overlay changed: {name}')
        previous_bytes[name] = raw

    # Read once into memory. Later stability checks reject concurrent edits;
    # the target can never contain mixed revisions of a file.
    current_bytes = {name: source_bytes(SOURCE, name) for name in sorted(CURRENT_FILES)}
    overlays = {**previous_bytes, **current_bytes, MAIN: isolated_main(previous_bytes[MAIN])}
    if len(overlays) != 85:
        raise RuntimeError(f'Expected 85 final overlay paths, found {len(overlays)}')

    excluded = {
        'apps/api/lib/mokaid/ai/dispatcher.ex',
        'apps/ai-worker/app/agents/dispatcher.py',
        'apps/api/lib/mokaid_web/controllers/fallback_controller.ex',
    }
    if excluded.intersection(overlays):
        raise RuntimeError('Unrelated dispatcher/Jev work entered the overlay')

    archive = subprocess.check_output(['git', 'archive', BASE, *ARCHIVE_PATHS], cwd=SOURCE)
    with tempfile.TemporaryDirectory(prefix='.mokaid-mail-agents-stage-', dir=TARGET.parent) as temporary:
        stage = Path(temporary) / 'release'
        stage.mkdir(mode=0o700)
        with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
            tar.extractall(stage, filter='data')

        copied = {}
        for name, raw in sorted(overlays.items()):
            destination = stage / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(raw)
            source_path = (SOURCE if name in current_bytes else PREVIOUS) / name
            shutil.copymode(source_path, destination)
            copied[name] = {
                'origin': 'partial_frozen_overlay' if name == MAIN else (
                    'current_workspace' if name in current_bytes else 'validated_previous_release'),
                'source': str(source_path),
                'source_sha256': sha256(current_bytes[name] if name in current_bytes else previous_bytes[name]),
                'copied_sha256': sha256(destination.read_bytes()),
            }

        # Same legacy Docker builder convention as the Mail-center release.
        api_ignore = stage / 'infra/docker/api.Dockerfile.dockerignore'
        shutil.copy2(api_ignore, stage / '.dockerignore')
        for name, raw in current_bytes.items():
            if source_bytes(SOURCE, name) != raw:
                raise RuntimeError(f'Source changed during release preparation: {name}')
        for name, raw in previous_bytes.items():
            if source_bytes(PREVIOUS, name) != raw:
                raise RuntimeError(f'Frozen source changed during release preparation: {name}')
        if PREVIOUS_MANIFEST.read_bytes() != manifest_raw:
            raise RuntimeError('Previous validation manifest changed during preparation')

        manifest = {
            'base': BASE,
            'expected_deployed_api': EXPECTED_DEPLOYED_API,
            'expected_deployed_worker': EXPECTED_DEPLOYED_WORKER,
            'previous_deployed_api': EXPECTED_DEPLOYED_API,
            'previous_deployed_worker': EXPECTED_DEPLOYED_WORKER,
            'runtime_architecture': 'linux/arm64',
            'previous_release': str(PREVIOUS),
            'previous_source_manifest': str(PREVIOUS_MANIFEST),
            'previous_source_manifest_sha256': sha256(manifest_raw),
            'previous_overlays_validated': len(previous_bytes),
            'current_overlays': sorted([*CURRENT_FILES, MAIN]),
            'current_source_sha256': {name: sha256(raw) for name, raw in sorted(current_bytes.items())},
            'files': {name: sha256(raw) for name, raw in sorted(overlays.items())},
            'copied_files': copied,
            'excluded_changes': [
                'dispatcher/Jev sources, API fallback change and related tests',
                'web changes', 'native application changes',
            ],
            'partial_overlay': {MAIN: 'previous frozen main.py plus app.tools.mail import and orchestrator timeout 22 to 55 only'},
            'build_context_note': 'API-specific dockerignore copied to isolated root for legacy builder; base asset-cooker retained for API image only',
            'api_dockerignore_sha256': sha256(api_ignore.read_bytes()),
            'release_script_sha256': sha256(Path(__file__).read_bytes()),
        }
        (stage / 'mail-agents-release-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        if TARGET.exists():
            raise RuntimeError(f'Target appeared while preparing release: {TARGET}')
        os.rename(stage, TARGET)
    print(json.dumps({'release': str(TARGET), 'previous_overlays': 51,
                      'current_overlays': 36, 'final_overlay_files': 85}))


if __name__ == '__main__':
    prepare()
