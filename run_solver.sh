#!/bin/bash

function log_stdout_and_stderr() {
    echo "$@"
    echo "$@" 1>&2
    echo "$@" >> /rundir/log.txt
}

rm -rf /rundir
mkdir /rundir

log_stdout_and_stderr "Hello from run_solver.sh"

MAX_N_SOLVERS_PER_PROCESS=64 # must be the limit set for Mallob at compile time
MALLOB_IMPCHECK=false # enable to use "ImpCheck" with on-the-fly LRAT checking
COMPETITION_MODE=false # set to false for local debugging

export MALLOC_CONF="thp:always"
export PATH=.:$PATH
export OMPI_MCA_btl_vader_single_copy_mechanism=none
export RDMAV_FORK_SAFE=1

log_stdout_and_stderr "Reading setup from $1 ..."
nglobalnodes=$(cat $1|wc -l)
nprocspernode=$(cat $1|head -1|grep -oE "slots=[0-9]+"|grep -oE "[0-9]+")
if [ "$nprocspernode" -ne "1" ]; then
    log_stdout_and_stderr "ERROR: Unexpected number of slots $nprocspernode (expected: 1)!"
    exit 1
fi

# Number of threads per MPI process: Initially set to available hardware threads,
# but at most $MAX_N_SOLVERS_PER_PROCESS.
n_threads_per_process=$(nproc)
if [ $n_threads_per_process -gt $MAX_N_SOLVERS_PER_PROCESS ]; then
    n_threads_per_process=$MAX_N_SOLVERS_PER_PROCESS
fi

# Let's check that the setup is actually exactly as we expect it to be in the competition.
if $COMPETITION_MODE; then
    if [[ "x$nglobalnodes" == x1 ]]; then
        # Parallel track
        if [[ $n_threads_per_process -ne 64 ]]; then
            log_stdout_and_stderr "ERROR: Detected parallel track configuration but found $n_threads_per_process threads per node (expected 64)!"
            log_stdout_and_stderr "Note: For local testing with deviating hardware, set variable COMPETITION_MODE to false in run_solver.sh"
            exit 1
        fi
    elif [[ "x$nglobalnodes" == x100 ]]; then
        # Cloud track
        if [[ $n_threads_per_process -ne 16 ]]; then
            log_stdout_and_stderr "ERROR: Detected cloud track configuration but found $n_threads_per_process threads per node (expected 16)!"
            log_stdout_and_stderr "Note: For local testing with deviating hardware, set variable COMPETITION_MODE to false in run_solver.sh"
            exit 1
        fi
    else
        log_stdout_and_stderr "ERROR: Configuration matches neither parallel nor cloud track ($nglobalnodes global nodes - expected 1 or 100)"
        log_stdout_and_stderr "Note: For local testing with deviating hardware, set variable COMPETITION_MODE to false in run_solver.sh"
        exit 1
    fi
fi

# In the parallel setup, we actually want to spawn two processes per node.
# We patch this in at this point here, adjusting the hostfile accordingly.
if [[ "x$nglobalnodes" == x1 ]]; then
    n_procs_per_node=2
    sed -i 's/slots=1/slots='$n_procs_per_node'/g' "$1"
else
    n_procs_per_node=1
fi

log_stdout_and_stderr "Hostfile $1:"
cat "$1" | while read line; do
    log_stdout_and_stderr "> $line"
done

# It remains somewhat unclear to us as to whether it is better to exploit all hardware threads of the available nodes
# or to only spawn as many solver threads as there are physical cores. We decided to strike a balance between the two.
n_threads_per_process=$(printf "%.0f" $(echo "(0.7 * $n_threads_per_process) / $n_procs_per_node"|bc -l))

# Assemble configuration-specific Mallob program options
opts=""
if $MALLOB_IMPCHECK; then
    # TRUSTED ("safe") setup with ImpCheck (with reduced number of threads where necessary)
    if [[ "$nglobalnodes" -gt 1 ]]; then
        # in the distributed setup, mix in a few Satisfying Assignment Boosting (SAB) threads - Kissat and YalSAT
        opts="${opts}"'-satsolver=c!k+(c!){'$(($n_threads_per_process-2))'}(c!l+(c!){'$(($n_threads_per_process-2))'}){7} '
        log_stdout_and_stderr "Setup: BIG, SAFE"
    else
        # no portfolio in parallel track: just sprinkle in a YalSAT local search thread
        opts="${opts}"'-satsolver=c!l+(c!){'$(($n_threads_per_process-2))'} '
        log_stdout_and_stderr "Setup: SAFE"
    fi
    opts="${opts}-rspaa=0 -otfc=1 -otfci=1 -max-lits-per-thread=35000000 "
else
    # Default ("quick") setup, using Kissat + some YalSAT
    if [[ "$nglobalnodes" -gt 1 ]]; then
        # distributed setup
        opts="${opts}-div-reduce=4 "
        log_stdout_and_stderr "Setup: BIG, QUICK"
    else
        # parallel setup
        log_stdout_and_stderr "Setup: QUICK"
    fi
    opts="${opts}-mono-app=SATWITHPRE -max-lits-per-thread=60000000 -presa=1 -ckas=1 -pl=1 -jc=1 "
fi

log_stdout_and_stderr "Running Mallob with $n_threads_per_process solver threads per process and $n_procs_per_node processes per host,\
 on $(hostname) as leader and with $(($nglobalnodes * $n_procs_per_node)) MPI processes ($nglobalnodes hosts) in total"

options="-mono=$2 -pre-cleanup=1 -seed=110519 -zero-only-logging=1 -v=2 -t=${n_threads_per_process} \
-processes-per-host=$n_procs_per_node -regular-process-allocation=1 -s2f=/rundir/solution.txt -terminate-abruptly=1 \
-trace-dir=/tmp -ft=1 $opts"

command="mpirun --mca btl_tcp_if_include eth0 --allow-run-as-root --hostfile $1 --bind-to none \
-x MALLOC_CONF=thp:always -x PATH=.:$PATH -x OMPI_MCA_btl_vader_single_copy_mechanism=none -x RDMAV_FORK_SAFE=1 \
./mallob $options"


# Run solver
log_stdout_and_stderr "EXECUTING: $command"
$command > /rundir/log-solver.txt


# Output trace files and errors, if present
for f in $(find /tmp -name 'mallob_thread_trace_*') ; do
    log_stdout_and_stderr "WARNING: Thread trace file $f found:"
    cat $f | while read line; do
        log_stdout_and_stderr "> $line"
    done
done
grep "\[ERROR\]" /rundir/log-solver.txt | while read line; do
    log_stdout_and_stderr "ERROR line in solver output: $line"
done

# Interpret output
log_stdout_and_stderr "Looking for result ..."
found_sat=false
noresult_maybeerror=false
if $MALLOB_IMPCHECK; then
    # We're in "safe" mode, so we explicitly confirm the result fingerprint reported by ImpCheck
    # so that we know the result is correct with very high confidence.

    confirm_args=$(cat /rundir/witness.* | tail -1 | awk '{print "-result="$2" -sig="$3}')
    confirm_cmd=$(grep -oE " -key-seed=[0-9]+ " /rundir/log-solver.txt | head -1 |
        awk '{print "./iimpcheck_confirm "$1" -formula='"$2 $confirm_args"'"}')

    if [ -z "$confirm_args" ] || [ -z "$confirm_cmd" ]; then
        log_stdout_and_stderr "No result found to confirm"
        noresult_maybeerror=true
    else
        log_stdout_and_stderr "Confirming result with $confirm_cmd"
        $confirm_cmd > /rundir/confirm-output.txt

        #log_stdout_and_stderr "Now outputting the confirmer log /rundir/confirm-output.txt"
        #cat /rundir/confirm-output.txt

        if grep -qE "^s VERIFIED SATISFIABLE" /rundir/confirm-output.txt ; then
            log_stdout_and_stderr "s SATISFIABLE"
            found_sat=true
        elif grep -qE "^s VERIFIED UNSATISFIABLE" /rundir/confirm-output.txt ; then
            log_stdout_and_stderr "s UNSATISFIABLE"
        elif grep -q "s NOT VERIFIED" /rundir/confirm-output.txt ; then
            log_stdout_and_stderr "s ERROR"
        else
            noresult_maybeerror=true
        fi
    fi

else
    # Usual non-checked mode: Just look for a proper result line returned by the solver.

    if grep -q "SATWP RES ~10~" /rundir/log-solver.txt ; then
        log_stdout_and_stderr "s SATISFIABLE"
        found_sat=true
    elif grep -q "SATWP RES ~20~" /rundir/log-solver.txt ; then
        log_stdout_and_stderr "s UNSATISFIABLE"
    elif grep -q "s SATISFIABLE" /rundir/log-solver.txt ; then
        log_stdout_and_stderr "s SATISFIABLE"
        found_sat=true
    elif grep -q "s UNSATISFIABLE" /rundir/log-solver.txt ; then
        log_stdout_and_stderr "s UNSATISFIABLE"
    else
        noresult_maybeerror=true
    fi
fi

# Cleanly output the found model (if any)
if $found_sat ; then
    cat /rundir/solution.txt* | grep -E "^v " | while read line; do
        log_stdout_and_stderr "$line"
    done
fi

# Report unknown result or error
if $noresult_maybeerror ; then
    if grep -q "\[ERROR\]" /rundir/log-solver.txt ; then
        log_stdout_and_stderr "s ERROR"
    elif grep -qE 'pid=[0-9]+ tid=[0-9]+ signal=(2|15)$' /rundir/log-solver.txt ; then
        log_stdout_and_stderr "s TIMEOUT"
    else
        log_stdout_and_stderr "s UNKNOWN"
    fi
fi

# Un-comment the following lines for debugging purposes.
#log_stdout_and_stderr "Appending full solver output (without result triggers)"
#grep -vE "^s " /rundir/log-solver.txt | while read line; do
#    log_stdout_and_stderr "> $line"
#done
