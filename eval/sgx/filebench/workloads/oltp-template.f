#
# OLTP workload template for disk benchmark
# The $BENCHMARK_DIR$ placeholder will be replaced at runtime
#

set $dir=$BENCHMARK_DIR$
set $eventrate=0
set $iosize=2k
set $nshadows=5
set $ndbwriters=30
set $usermode=200000
set $filesize=10m
set $memperthread=1m
set $workingset=0
set $logfilesize=10m
set $nfiles=50
set $nlogfiles=1
set $directio=0
eventgen rate = $eventrate

# Define a datafile and logfile
define fileset name=datafiles,path=$dir,size=$filesize,entries=$nfiles,dirwidth=1024,prealloc=100,reuse
define fileset name=logfile,path=$dir,size=$logfilesize,entries=$nlogfiles,dirwidth=1024,prealloc=100,reuse

define process name=lgwr,instances=1
{
  thread name=lgwr,memsize=$memperthread
  {
    flowop write name=lg-write,filesetname=logfile,
        iosize=256k,random,directio=$directio
  }
}

# Define database writer processes
define process name=dbwr,instances=$ndbwriters
{
  thread name=dbwr,memsize=$memperthread
  {
    flowop write name=dbwrite-a,filesetname=datafiles,
        iosize=$iosize,workingset=$workingset,random,iters=100,opennext,directio=$directio
    flowop hog name=dbwr-hog,value=10000
  }
}

define process name=shadow,instances=$nshadows
{
  thread name=shadow,memsize=$memperthread
  {
    flowop read name=shadowread,filesetname=datafiles,
        iosize=$iosize,workingset=$workingset,random,opennext,directio=$directio
    flowop hog name=shadowhog,value=$usermode
    flowop eventlimit name=random-rate
  }
}

echo "OLTP Version 3.0  personality successfully loaded"

run 60

