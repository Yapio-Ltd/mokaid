#!/bin/sh
set -eu
/sdk/bin/dxc --version
for specification in \
  vsMain:vs_6_0:office.vs \
  psMain:ps_6_0:office.ps \
  postVertex:vs_6_0:office.post.vs \
  bloomDownsample:ps_6_0:bloomDownsample.ps \
  bloomBlur:ps_6_0:bloomBlur.ps \
  officeComposite:ps_6_0:officeComposite.ps
do
  entry=${specification%%:*}
  remainder=${specification#*:}
  profile=${remainder%%:*}
  output=${remainder#*:}
  /sdk/bin/dxc -Ges -WX -E "$entry" -T "$profile" -Fo "/output/$output.dxil" /source/office.hlsl
  /sdk/bin/dxc -dumpbin "/output/$output.dxil" > "/output/$output.reflection.txt"
  printf 'PASS %s (%s)\n' "$entry" "$profile"
done
