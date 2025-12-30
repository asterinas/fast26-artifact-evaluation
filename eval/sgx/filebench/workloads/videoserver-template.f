#
# Videoserver workload template for disk benchmark
# The $BENCHMARK_DIR$ placeholder will be replaced at runtime
#

set $dir=$BENCHMARK_DIR$
set $eventrate=96
set $filesize=1g
set $nthreads=48
set $numactivevids=5
set $numpassivevids=30
set $reuseit=false
set $readiosize=256k
set $writeiosize=1m
set $passvidsname=passivevids
set $actvidsname=activevids
set $repintval=10
eventgen rate=$eventrate

define fileset name=$actvidsname,path=$dir,size=$filesize,entries=$numactivevids,dirwidth=4,prealloc,paralloc,reuse=$reuseit
define fileset name=$passvidsname,path=$dir,size=$filesize,entries=$numpassivevids,dirwidth=20,prealloc=50,paralloc,reuse=$reuseit

define process name=vidwriter,instances=1
{
  thread name=vidwriter,memsize=10m,instances=1
  {
    flowop deletefile name=vidremover,filesetname=$passvidsname
    flowop createfile name=wrtopen,filesetname=$passvidsname,fd=1
    flowop writewholefile name=newvid,iosize=$writeiosize,fd=1,srcfd=1
    flowop closefile name=wrtclose, fd=1
    flowop delay name=replaceinterval, value=$repintval
  }
}

define process name=vidreaders,instances=1
{
  thread name=vidreaders,memsize=10m,instances=$nthreads
  {
    flowop read name=vidreader,filesetname=$actvidsname,iosize=$readiosize
    flowop bwlimit name=serverlimit, target=vidreader
  }
}

echo  "Video Server Version 3.0 personality successfully loaded"

run 60

