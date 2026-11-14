#!/bin/sh
# Fetch training pairs for the high-resolution retouching model: FFHQR (retouched, 1024 px PNG, tar per 10000 from UBC)
# and the matching FFHQ originals (tar per 1000 from the gaunernst/ffhq-1024-wds mirror on Hugging Face).
# usage: fetch_ffhq.sh <first part> <last part>      e.g. 1 3 = photos 00000-29999. Resumes where it stopped.
R=~/LRCDF/data/ffhqr; O=~/LRCDF/data/ffhq1024; mkdir -p $R $O
p=$1
while [ $p -le $2 ]; do
  k=$(( (p - 1) * 10 ))
  while [ $k -lt $(( p * 10 )) ]; do
    n=$(printf "%02d000" $k)
    [ -f $O/$n.done ] || { curl -sL --retry 8 --retry-delay 20 -C - -o $O/$n.tar "https://huggingface.co/datasets/gaunernst/ffhq-1024-wds/resolve/main/$n.tar" && touch $O/$n.done; }
    k=$(( k + 1 ))
  done
  [ -f $R/part$p.done ] || { curl -sL --retry 8 --retry-delay 20 -C - -o $R/ffhqr.part$p.tar "https://www.cs.ubc.ca/research/AutoRetouch/ffhqr.part$p.tar" && touch $R/part$p.done; }
  echo "part $p complete $(date)"
  p=$(( p + 1 ))
done
