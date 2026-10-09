# Image-only scheduler. Disko generates Bash; Nu owns the job barrier and the
# private member registries. Every worker receives the original arguments and
# exported environment, and starts in the caller's working directory.

def image-workers [nproc: string] {
    let requested = ($env.IDR_IMAGE_SETUP_JOBS? | default '0' | into string)
    if $requested !~ '^\d{1,9}$' {
        print -e 'IDR_IMAGE_SETUP_JOBS must be zero or a positive integer'
        exit 2
    }
    let override = $requested | into int
    if $override > 0 { return $override }

    let cpus = ^$nproc | into int
    let budget = ($env.NIX_BUILD_CORES? | default '0' | into string)
    let cpu_budget = if $budget =~ '^\d{1,9}$' and ($budget | into int) > 0 {
        [$cpus ($budget | into int)] | math min
    } else { $cpus }
    let available = if ('/proc/meminfo' | path exists) {
        open --raw /proc/meminfo
        | parse --regex 'MemAvailable:\s+(?<kib>\d+)'
        | get kib.0?
        | default '0'
        | into int
    } else { 0 }
    # Reserve 2 GiB per formatter, including LUKS Argon2 and filesystem tools.
    let workers = [2 $cpu_budget ($available // 2097152)] | math min | into int
    [$workers 1] | math max
}

def run-script [script: string, arguments: list<string>, bash: string] {
    try {
        # An external command before the final status expression inherits the
        # caller's stdin/stdout/stderr. Collect forces evaluation inside try,
        # including spawn failures, without reopening or buffering those FDs.
        do --capture-errors {
            ^$bash $script ...$arguments
            0
        } | collect
    } catch {|error|
        # try clears Nu's interruption state while running catch. Preserve the
        # interrupted path so setup cannot clean up beneath surviving workers.
        if $error.msg == 'Operation interrupted' { error make { msg: $error.msg } }
        if $error.exit_code? != null {
            $error.exit_code
        } else {
            print -e $'idr-mk-images: cannot run ($script) with ($bash): ($error.msg)'
            1
        }
    }
}

def run-jobs [scripts: list<string>, arguments: list<string>, bash: string, workers: int] {
    print -e $'idr-mk-images: preparing ($scripts | length) image jobs with ($workers) workers'
    # Interactive groups must run in the foreground: par-each does not retain
    # the original stdin when an external command inherits its output streams.
    if $workers == 1 {
        for script in $scripts {
            let status = run-script $script $arguments $bash
            if $status != 0 { return $status }
        }
        return 0
    }
    for batch in ($scripts | chunks $workers) {
        # Collect the entire batch before considering any failure. Returning a
        # status rather than throwing inside par-each lets siblings finish.
        let statuses = $batch | par-each --threads $workers --keep-order {|script|
            run-script $script $arguments $bash
        } | collect
        let failures = $statuses | where {|status| $status != 0 }
        if not ($failures | is-empty) { return ($failures | first) }
    }
    0
}

def merge-registries [root: string, directories: list<string>] {
    for directory in $directories {
        for registry in (glob (($root | path join $directory '*') | into glob)) {
            if ($registry | path type) == 'file' {
                open --raw $registry | save --append ($root | path join ($registry | path basename))
            }
        }
    }
}

# Used by the small generated Bash entrypoint to encode "$@" without quoting
# loss, including empty strings, quotes, newlines and arguments beginning '-'.
def --wrapped 'main arguments' [...arguments: string] {
    # Wrapped rest parameters preserve the literal '--' on both supported Nu
    # versions. Drop our delimiter, retaining any delimiter in the original argv.
    $arguments | skip 1 | to json --raw
}

def 'main workers' [--nproc: string = 'nproc'] { image-workers $nproc }

def --wrapped 'main run' [
    --bash: string
    --nproc: string = 'nproc'
    --script-args-json: string = '[]'
    ...scripts: string
] {
    let arguments: list<string> = $script_args_json | from json
    let jobs = if ($scripts.0? | default '') == '--' { $scripts | skip 1 } else { $scripts }
    exit (run-jobs $jobs $arguments $bash (image-workers $nproc))
}

def 'main setup' [
    plan: string
    --bash: string
    --nproc: string = 'nproc'
    --mktemp: string = 'mktemp'
    --script-args-json: string = '[]'
] {
    let arguments: list<string> = $script_args_json | from json
    let workers = image-workers $nproc
    let groups = open --raw $plan | from json
    let root = ^$mktemp -d | str trim
    mut status = 0
    $env.IDR_IMAGE_SETUP_ROOT = $root | path join '.workers'
    mkdir $env.IDR_IMAGE_SETUP_ROOT
    for group in $groups {
        if $group.parallel and $workers > 1 {
            print -e $'idr-mk-images: preparing ($group.jobs | length) image jobs with ($workers) workers'
            # Do not use a lazy pipeline across batches: the barrier must
            # stop dispatching as soon as one complete batch has failed.
            let batches = $group.jobs | chunks $workers | collect
            for batch in $batches {
                let results = $batch | par-each --threads $workers --keep-order {|job|
                    let registry = $env.IDR_IMAGE_SETUP_ROOT | path join $job.registry
                    mkdir $registry
                    with-env { IDR_DISKO_DEVICES_DIR: $registry } {
                        run-script $job.script $arguments $bash
                    }
                } | collect
                let failures = $results | where {|result| $result != 0 }
                if not ($failures | is-empty) { $status = $failures | first; break }
            }
            if $status == 0 {
                merge-registries $root ($group.jobs | get registry | each {|name| $'.workers/($name)'})
            }
        } else {
            $status = with-env { IDR_DISKO_DEVICES_DIR: $root } {
                run-jobs ($group.jobs | get script) $arguments $bash 1
            }
        }
        if $status != 0 { break }
    }
    # Nu can interrupt par-each before its external commands finish. Cleanup
    # only follows a completed barrier; interruption retains the registries
    # rather than removing files still used by live workers.
    rm --recursive --force $root
    exit $status
}

def main [] { help main }
