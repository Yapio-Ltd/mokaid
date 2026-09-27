from pathlib import Path
import os, subprocess, tempfile, json, hashlib
root = Path('/private/tmp/mokaid-mail-agents-release-20260927')
manifest = json.loads((root/'mail-agents-release-manifest.json').read_text())
tag = 'mail-agents-20260927-' + hashlib.sha256(json.dumps(manifest,sort_keys=True).encode()).hexdigest()[:10]
registry = '660601648321.dkr.ecr.il-central-1.amazonaws.com'
env = dict(os.environ, DOCKER_HOST='unix:///Users/olimservice/.colima/default/docker.sock', AWS_PROFILE='mokaid', AWS_DEFAULT_REGION='il-central-1')
images = {}
with tempfile.TemporaryDirectory(prefix='mokaid-mail-agents-ecr-') as cfg:
 os.chmod(cfg,0o700)
 env['DOCKER_CONFIG'] = cfg
 token = subprocess.check_output(['aws','ecr','get-login-password'],env=env)
 subprocess.run(['docker','login','--username','AWS','--password-stdin',registry],input=token,env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True)
 del token
 for local, repo in [('mokaid-mail-agents-api:20260927','mokaid-api'),('mokaid-mail-agents-worker:20260927','mokaid-ai-worker')]:
  remote = registry+'/'+repo+':'+tag
  subprocess.run(['docker','tag',local,remote],env=env,check=True)
  with open('/private/tmp/'+repo+'-mail-agents-push.log','w') as log:
   subprocess.run(['docker','push',remote],env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
  info = json.loads(subprocess.check_output(['aws','ecr','describe-images','--repository-name',repo,'--image-ids','imageTag='+tag,'--output','json'],env=env))['imageDetails'][0]
  images[repo] = {'tag':tag,'digest':info['imageDigest'],'image':registry+'/'+repo+'@'+info['imageDigest']}
  print(json.dumps({repo:images[repo]}),flush=True)
(root/'images.json').write_text(json.dumps(images,indent=2)+'\n')
print('Temporary registry credentials removed',flush=True)
