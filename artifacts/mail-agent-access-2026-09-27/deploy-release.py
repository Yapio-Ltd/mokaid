import os, json, subprocess, sys
from pathlib import Path
kind, phase = sys.argv[1:]
assert kind in ['api','ai-worker'] and phase in ['prepare','migrate','deploy']
root = Path('/private/tmp/mokaid-mail-agents-release-20260927')
images = json.loads((root/'images.json').read_text())
service = 'mokaid-prod-'+kind
output = root/(kind+'-ecs-output')
env = dict(os.environ, PYTHONUNBUFFERED='1', AWS_PROFILE='mokaid', AWS_DEFAULT_REGION='il-central-1', CLUSTER='mokaid-prod', SERVICE=service, CONTAINER=service, IMAGE=images['mokaid-'+kind]['image'], GITHUB_OUTPUT=str(output), POLL_INTERVAL_SECONDS='10')
if phase == 'prepare':
 assert not output.exists(), 'Preparation already has a receipt'
 active = json.loads(subprocess.check_output(['aws','ecs','describe-services','--cluster','mokaid-prod','--services',service,'--output','json'],env=env))['services'][0]['taskDefinition']
 expected = ':58' if kind == 'api' else ':51'
 assert active.endswith(expected), 'Production changed; reconcile before deploying'
 output.touch(mode=0o600)
else:
 values = dict(line.split('=',1) for line in output.read_text().splitlines() if '=' in line)
 env.update(TASK_DEFINITION=values['task_definition'], PREVIOUS_TASK_DEFINITION=values['previous_task_definition'])
subprocess.run([sys.executable,str(root/'.github/scripts/ecs_deploy.py'),phase],env=env,check=True)
